%% =========================================================================
%  Case A: Smart Home Energy Management (PV + Battery + EV)
%  EGS Individual Coursework
%  Two dispatch policies compared:
%    Policy 1 - Rule-based self-consumption greedy dispatch
%    Policy 2 - Linear-programme (LP) cost minimisation (linprog)
%  EV Extension: daily EV charging requirement met before departure
% =========================================================================
clc; clear; close all;

%% =========================================================================
%  SECTION 1: LOAD DATA
% =========================================================================
fprintf('=== Loading datasets ===\n');
data    = readtable('caseA_smart_home_30min_summer.csv');
ev_data = readtable('caseA_ev_events.csv');

% -- Time parameters --
dt     = 0.5;            % timestep length [h]  (30-minute resolution)
T      = height(data);   % total number of timesteps  (30 days * 48 = 1440)
n_days = T * dt / 24;    % number of days (should be 30)

% Parse absolute time (datetime) for accurate date/time plotting
if iscell(data.timestamp)
    t_datetime = datetime(data.timestamp, 'InputFormat', 'yyyy-MM-dd HH:mm:ss');
elseif isstring(data.timestamp)
    t_datetime = datetime(data.timestamp, 'InputFormat', 'yyyy-MM-dd HH:mm:ss');
else
    t_datetime = data.timestamp; % If already datetime type
end

% Force default format to English/Numerical to avoid local OS language issues
t_datetime.Format = 'MM-dd HH:mm'; 

% -- Signals --
PV     = data.pv_kw;                        % PV generation [kW]
Load   = data.base_load_kw;                 % Base electrical load [kW]
lam_b  = data.import_tariff_gbp_per_kwh;    % Buy (import) tariff  [£/kWh]
lam_s  = data.export_price_gbp_per_kwh;     % Sell (export) price  [£/kWh]

fprintf('  Timesteps T=%d | dt=%.1f h | Days=%d\n', T, dt, n_days);
fprintf('  Total PV energy   : %.1f kWh\n', sum(PV)*dt);
fprintf('  Total Load energy : %.1f kWh\n', sum(Load)*dt);

%% =========================================================================
%  SECTION 2: BATTERY PARAMETERS
% =========================================================================
batt.E_cap   = 5.0;              % Usable energy capacity [kWh]
batt.P_ch    = 2.5;              % Max charge power      [kW]
batt.P_dis   = 2.5;              % Max discharge power   [kW]
batt.eta_ch  = 0.95;             % Charge efficiency     (round-trip = 0.95^2 ≈ 0.90)
batt.eta_dis = 0.95;             % Discharge efficiency
batt.SOC_min = 0.0;              % Min SOC               [kWh]
batt.SOC_max = batt.E_cap;       % Max SOC               [kWh]
batt.SOC0    = 0.5 * batt.E_cap; % Initial SOC           [kWh]  = 2.5 kWh

fprintf('\n=== Battery Parameters ===\n');
fprintf('  Capacity: %.1f kWh | P_ch_max: %.1f kW | P_dis_max: %.1f kW\n',...
    batt.E_cap, batt.P_ch, batt.P_dis);

%% =========================================================================
%  SECTION 3: EV PARAMETERS & TIMESTEP MAPPING
% =========================================================================
fprintf('\n=== Processing EV Events ===\n');
n_events   = height(ev_data);
ev.avail   = zeros(T, 1);   
ev.P_max   = zeros(T, 1);   
ev.active_event = zeros(T, 1); 

ev.E_req   = zeros(n_events, 1);   
ev.arr_ts  = zeros(n_events, 1);   
ev.dep_ts  = zeros(n_events, 1);   

% Use parsed global start time for relative hours calculation
t_start = t_datetime(1);

for e = 1:n_events
    if iscell(ev_data.arrival_time)
        arr_t = datetime(ev_data.arrival_time{e}, 'InputFormat', 'yyyy-MM-dd HH:mm:ss');
        dep_t = datetime(ev_data.departure_time{e}, 'InputFormat', 'yyyy-MM-dd HH:mm:ss');
    elseif isstring(ev_data.arrival_time)
        arr_t = datetime(ev_data.arrival_time(e), 'InputFormat', 'yyyy-MM-dd HH:mm:ss');
        dep_t = datetime(ev_data.departure_time(e), 'InputFormat', 'yyyy-MM-dd HH:mm:ss');
    else
        arr_t = ev_data.arrival_time(e);
        dep_t = ev_data.departure_time(e);
    end
    
    arr_h = hours(arr_t - t_start);
    dep_h = hours(dep_t - t_start);
    
    E_req    = ev_data.required_energy_kwh(e);
    P_ev_max = ev_data.max_charge_power_kw(e);
    
    arr_ts = ceil(arr_h / dt) + 1;    
    dep_ts = floor(dep_h / dt);       
    
    arr_ts = max(arr_ts, 1);
    dep_ts = min(dep_ts, T);
    
    n_slots = max(dep_ts - arr_ts + 1, 0);
    if n_slots > 0
        ev.avail(arr_ts:dep_ts)  = 1;
        ev.P_max(arr_ts:dep_ts)  = P_ev_max;
        ev.active_event(arr_ts:dep_ts) = e;
    end
    ev.E_req(e)  = E_req;
    ev.arr_ts(e) = arr_ts;
    ev.dep_ts(e) = dep_ts;
end
fprintf('  EV events loaded: %d events\n', n_events);

%% =========================================================================
%  SECTION 4: POLICY 1 — RULE-BASED SELF-CONSUMPTION DISPATCH
% =========================================================================
fprintf('\n=== Running Policy 1: Rule-Based Self-Consumption ===\n');
p1.p_ch  = zeros(T,1);
p1.p_dis = zeros(T,1);
p1.p_imp = zeros(T,1);
p1.p_exp = zeros(T,1);
p1.p_ev  = zeros(T,1);
p1.soc   = zeros(T+1,1);
p1.soc(1) = batt.SOC0;

ev_delivered_p1 = zeros(n_events, 1);

for t = 1:T
    surplus = PV(t) - Load(t);   
    
    % Step 1: EV
    if ev.avail(t)
        event_idx = ev.active_event(t);
        ev_remaining = ev.E_req(event_idx) - ev_delivered_p1(event_idx);
        slots_left = ev.dep_ts(event_idx) - t;  
        
        if slots_left > 0
            p_ev_min = max(0, (ev_remaining - slots_left * ev.P_max(t) * dt) / dt);
        else
            p_ev_min = min(ev_remaining / dt, ev.P_max(t)); 
        end
        
        p_ev_desired = min(ev.P_max(t), max(0, ev_remaining / dt));
        p_ev_from_surplus = min(p_ev_desired, max(0, surplus));
        surplus = surplus - p_ev_from_surplus;
        
        p_ev_mandatory = max(0, p_ev_min - p_ev_from_surplus);
        p1.p_ev(t) = p_ev_from_surplus + p_ev_mandatory;
        p1.p_ev(t) = min(p1.p_ev(t), ev.P_max(t));
        ev_delivered_p1(event_idx) = ev_delivered_p1(event_idx) + p1.p_ev(t) * dt;
        
        if p_ev_mandatory > 0
            surplus = surplus - p_ev_mandatory;  
        end
    end
    
    % Step 2: Battery Charge
    if surplus > 0
        headroom = batt.SOC_max - p1.soc(t);      
        p_ch_avail = min(surplus, batt.P_ch);      
        p_ch_avail = min(p_ch_avail, headroom / (batt.eta_ch * dt)); 
        p1.p_ch(t) = max(0, p_ch_avail);
        surplus = surplus - p1.p_ch(t);
    end
    
    % Step 3: Export
    if surplus > 0
        p1.p_exp(t) = surplus;
        surplus = 0;
    end
    
    % Step 4: Battery Discharge
    if surplus < 0
        deficit = -surplus;
        energy_avail = p1.soc(t) - batt.SOC_min;  
        p_dis_avail  = min(deficit, batt.P_dis);
        p_dis_avail  = min(p_dis_avail, energy_avail * batt.eta_dis / dt);
        p1.p_dis(t)  = max(0, p_dis_avail);
        deficit = deficit - p1.p_dis(t);
    else
        deficit = 0;
    end
    
    % Step 5: Import
    if deficit > 0
        p1.p_imp(t) = deficit;
    end
    
    p1.soc(t+1) = p1.soc(t) + (p1.p_ch(t)*batt.eta_ch - p1.p_dis(t)/batt.eta_dis) * dt;
    p1.soc(t+1) = max(batt.SOC_min, min(batt.SOC_max, p1.soc(t+1))); 
end
p1.soc_final = p1.soc(T+1);

%% =========================================================================
%  SECTION 5: POLICY 2 — LP COST MINIMISATION
% =========================================================================
fprintf('\n=== Running Policy 2: LP Cost Minimisation ===\n');
N = 6*T + 1;   

idx_ch  = @(t) t;
idx_dis = @(t) T + t;
idx_imp = @(t) 2*T + t;
idx_exp = @(t) 3*T + t;
idx_ev  = @(t) 4*T + t;
idx_soc = @(t) 5*T + t;   

f = zeros(N, 1);
for t = 1:T
    f(idx_imp(t)) =  dt * lam_b(t);   
    f(idx_exp(t)) = -dt * lam_s(t);   
end

n_eq = 2*T + 1;
Aeq = sparse(n_eq, N);
beq = zeros(n_eq, 1);

for t = 1:T
    row = t;
    Aeq(row, idx_ch(t))  =  1;
    Aeq(row, idx_dis(t)) = -1;
    Aeq(row, idx_imp(t)) = -1;
    Aeq(row, idx_exp(t)) =  1;
    Aeq(row, idx_ev(t))  =  1;
    beq(row) = PV(t) - Load(t);
end

for t = 1:T
    row = T + t;
    Aeq(row, idx_soc(t+1)) =  1;
    Aeq(row, idx_soc(t))   = -1;
    Aeq(row, idx_ch(t))    = -batt.eta_ch * dt;
    Aeq(row, idx_dis(t))   =  (1/batt.eta_dis) * dt;
    beq(row) = 0;
end

row = 2*T + 1;
Aeq(row, idx_soc(1)) = 1;
beq(row) = batt.SOC0;

n_ineq = n_events + 1;
Aineq = sparse(n_ineq, N);
bineq = zeros(n_ineq, 1);

for e = 1:n_events
    if ev.E_req(e) > 0
        for t = ev.arr_ts(e):ev.dep_ts(e)
            Aineq(e, idx_ev(t)) = -dt;
        end
        bineq(e) = -ev.E_req(e);
    end
end

Aineq(n_events+1, idx_soc(T+1)) = -1;
bineq(n_events+1) = -batt.SOC0;

lb = zeros(N, 1);
ub = inf(N, 1);
for t = 1:T
    ub(idx_ch(t))  = batt.P_ch;
    ub(idx_dis(t)) = batt.P_dis;
    ub(idx_ev(t))  = ev.P_max(t);   
end
for t = 1:T+1
    lb(idx_soc(t)) = batt.SOC_min;
    ub(idx_soc(t)) = batt.SOC_max;
end

options = optimoptions('linprog', 'Display', 'off', ...
    'Algorithm', 'dual-simplex');
[x_opt, fval, exitflag] = linprog(f, Aineq, bineq, Aeq, beq, lb, ub, options);

p2.p_ch  = x_opt(idx_ch(1:T));
p2.p_dis = x_opt(idx_dis(1:T));
p2.p_imp = x_opt(idx_imp(1:T));
p2.p_exp = x_opt(idx_exp(1:T));
p2.p_ev  = x_opt(idx_ev(1:T));
p2.soc   = x_opt(idx_soc(1:T+1));
p2.soc_final = p2.soc(T+1);

%% =========================================================================
%  SECTION 8: PLOTS
% =========================================================================
fprintf('\n=== Generating Plots ===\n');

% --- Figure 1: Power Flows - First 3 Days ---
t_plot = 1:144;   
t_dt3  = t_datetime(t_plot); % Extract datetime objects for the first 3 days

fig1 = figure('Name','Power Flows - First 3 Days','Position',[50 50 1200 800]);

subplot(3,2,1);
plot(t_dt3, PV(t_plot),'g','LineWidth',1.5); hold on;
plot(t_dt3, Load(t_plot),'k--','LineWidth',1.5);
plot(t_dt3, ev.avail(t_plot).*2,'b:','LineWidth',1);
ylabel('Power [kW]'); title('PV & Base Load (3 days)');
legend('PV','Base Load','EV connected','Location','NorthEast');
grid on; xtickformat('MM-dd HH:mm'); xlabel('Date & Time');

subplot(3,2,2);
area(t_dt3, [PV(t_plot), p1.p_dis(t_plot), p1.p_imp(t_plot)], 'FaceAlpha',0.5);
hold on; plot(t_dt3, Load(t_plot)+p1.p_ev(t_plot),'k--','LineWidth',2);
title('Policy 1: Supply Sources');
legend('PV','Battery Discharge','Grid Import','Total Demand','Location','NorthEast');
ylabel('Power [kW]'); grid on; xtickformat('MM-dd HH:mm'); xlabel('Date & Time');

subplot(3,2,3);
plot(t_dt3, p1.soc(t_plot),'b','LineWidth',1.5); hold on;
yline(batt.SOC0,'r--'); yline(batt.SOC_max,'k:'); yline(batt.SOC_min,'k:');
title('Policy 1: Battery SOC'); ylabel('SOC [kWh]');
legend('SOC','Initial','Max','Min'); 
grid on; xtickformat('MM-dd HH:mm'); xlabel('Date & Time');

subplot(3,2,4);
area(t_dt3, [PV(t_plot), p2.p_dis(t_plot), p2.p_imp(t_plot)], 'FaceAlpha',0.5);
hold on; plot(t_dt3, Load(t_plot)+p2.p_ev(t_plot),'k--','LineWidth',2);
title('Policy 2: Supply Sources');
legend('PV','Battery Discharge','Grid Import','Total Demand','Location','NorthEast');
ylabel('Power [kW]'); grid on; xtickformat('MM-dd HH:mm'); xlabel('Date & Time');

subplot(3,2,5);
plot(t_dt3, p2.soc(t_plot),'r','LineWidth',1.5); hold on;
yline(batt.SOC0,'r--'); yline(batt.SOC_max,'k:'); yline(batt.SOC_min,'k:');
title('Policy 2: Battery SOC'); ylabel('SOC [kWh]');
legend('SOC','Initial','Max','Min'); 
grid on; xtickformat('MM-dd HH:mm'); xlabel('Date & Time');

subplot(3,2,6);
yyaxis left; plot(t_dt3, lam_b(t_plot)*100,'b-'); ylabel('Tariff [p/kWh]');
yyaxis right; plot(t_dt3, p2.p_ev(t_plot),'g--'); ylabel('EV power [kW]');
title('Import Tariff & EV Charging (P2)'); 
grid on; xtickformat('MM-dd HH:mm'); xlabel('Date & Time');

% --- Figure 2: Full 30-day SOC Comparison ---
fig2 = figure('Name','30-day SOC Comparison','Position',[50 500 1200 400]);
plot(t_datetime(1:T), p1.soc(1:T),'b','LineWidth',1); hold on;
plot(t_datetime(1:T), p2.soc(1:T),'r','LineWidth',1);
yline(batt.SOC0,'k--','LineWidth',1.5);
ylabel('SOC [kWh]'); xlabel('Date');
title('Battery State of Charge - 30 Days');
legend('Policy 1 (Self-Consumption)','Policy 2 (LP)','Initial SOC');
xtickformat('MM-dd'); % 30-day span, show Month-Day only
grid on;

% --- Figure 3: Daily Cost Breakdown ---
daily_cost_p1 = zeros(n_days,1);
daily_cost_p2 = zeros(n_days,1);
for d = 1:n_days
    ts = (d-1)*48+1 : d*48;
    daily_cost_p1(d) = sum(p1.p_imp(ts).*lam_b(ts))*dt - sum(p1.p_exp(ts).*lam_s(ts))*dt;
    daily_cost_p2(d) = sum(p2.p_imp(ts).*lam_b(ts))*dt - sum(p2.p_exp(ts).*lam_s(ts))*dt;
end

fig3 = figure('Name','Daily Cost Breakdown','Position',[50 900 1000 400]);
t_days = t_datetime(1:48:T); % Extract start of each day for the x-axis
bar(t_days, [daily_cost_p1, daily_cost_p2]);
legend('Policy 1','Policy 2'); xlabel('Date'); ylabel('Net Cost [£]');
title('Daily Net Electricity Cost Comparison');
xtickformat('MM-dd');
grid on;

% --- Figure 4: EV Charging Behavior (First 7 Days) ---
fig4 = figure('Name','EV Charging - Policy 2','Position',[700 50 900 400]);
t_week = 1:336;  
t_dt_week = t_datetime(t_week);
yyaxis left;
area(t_dt_week, p2.p_ev(t_week), 'FaceAlpha',0.5,'FaceColor','g');
ylabel('EV Charge Power [kW]'); ylim([0 max(ev.P_max)*1.2]);
yyaxis right;
plot(t_dt_week, lam_b(t_week)*100,'r-','LineWidth',1.5);
ylabel('Import Tariff [p/kWh]');
xlabel('Date & Time'); title('EV Charging vs Import Tariff - First 7 Days (Policy 2)');
legend('EV Power','Tariff','Location','NorthEast'); 
xtickformat('MM-dd HH:mm');
grid on;

fprintf('  Figures updated with explicit Datetime axes.\n');