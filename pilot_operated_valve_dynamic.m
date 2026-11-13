%% PILOT-OPERATED MAIN VALVE - DYNAMIC SIMULATION
%
% Takes the valve and regulator sizes and the inlet conditions, then
% calculates the internal flow step by step in time and gives the flow and
% pressure at the outlet of the regulator and of the main valve.
%
% Layout:
%
%   INLET P1,T1 --+-----------------> MAIN VALVE -----> OUTLET P2,T2 --> load
%                 |                      ^
%                 |                      | CLOSED by the BIG PISTON
%                 |                      | (the main spring opens it)
%                 +--> PILOT REGULATOR --> PISTON CHAMBER Pr,Tr --> BLEED --> ambient
%                      (set: 5 bar)        (regulated pressure)
%
%  1. The pilot regulator takes gas just after the main valve inlet (P1, T1).
%  2. It reduces the pressure to the set value (5 bar) in the piston chamber.
%     Its spring opens it; the regulated pressure on its sensing piston closes it.
%  3. A small bleed orifice vents the piston chamber, so the regulator always
%     has a small flow and can also lower the pressure.
%  4. The main spring holds the main valve OPEN. The regulated pressure
%     pushes the big piston, which compresses the spring and CLOSES the valve.
%     Lower pressure relieves the spring and the valve opens again.
%     valve opening = piston stroke - piston displacement.
%     The piston displacement at the design point is an input: the code sets
%     the spring preload so that the piston sits there at the regulated pressure.
%  5. The main flow goes through the main valve to the outlet volume and on
%     to the load (the consumer downstream).
%
% Assumptions:
%  - Pressures are gauge, bar(g). Gas is ideal. No heat loss to the walls.
%  - The back side of the big piston is vented to ambient.
%  - The main valve plug is pressure-balanced (gas pressure does not push it).
%  - The load is an orifice to ambient, sized by the code so that the design
%    flow passes when the piston is at its design displacement.
%  - Seal friction is represented by a damping ratio.
%
% Flow through any opening:  m = Cd*A*f(g)*N*Pu/sqrt(R*Tu),  Cd from input "flow_coeff_law"
% Conical seat flow area:    A = pi*x*sin(th)*(d - x*sin(th)*cos(th)),
%                            d = seat diameter = OUTER (large) sealing diameter of the poppet
% Gas volume:  dP/dt = [g*R*(Tin*m_in - T*m_out) - g*P*dV/dt] / V
%              dT/dt = R*T^2/(V*P)*[(g*Tin/T - 1)*m_in - (g-1)*m_out] - (g-1)*T/V*dV/dt
% Runs in MATLAB or GNU Octave, no toolboxes needed.

clear; clc; close all;

%% ======================= INPUTS (edit only here) =========================

%% 1. INPUTS - MAIN VALVE INLET
P1_barg          = 10;       % inlet pressure                    [bar(g)]
T1_K             = 600;      % inlet temperature                 [K]
m_design_kgs     = 0.6;      % design flow through the main valve [kg/s]
t_ramp_s         = 0.05;     % time for the inlet pressure to rise from 0 to P1 [s]

%% 2. INPUTS - GAS AND AMBIENT
gas_R            = 287;      % gas constant              [J/(kg K)]  air 287
gas_gamma        = 1.4;      % ratio of specific heats   [-]         air 1.4 (1.38 at 600 K)
P_atm_bar        = 1.01325;  % ambient pressure          [bar(a)]
T_start_K        = 293;      % gas temperature inside the valve before start [K]
flow_coeff_law   = 2;        % flow coefficient Cd of every opening:
                             %   1 = thesis rule      Cd = 1 - 0.7*Pd/Pu
                             %   2 = constant value   Cd = Cd_constant   (default: fits measured regulator data best)
                             %   3 = Perry rule for a sharp-edged orifice (0.84 choked ... 0.60 at no pressure drop);
                             %       this is the variable-Cq option of the Amesim pneumatic library
Cd_constant      = 0.70;     % used only with law 2 [-]. 0.70 = value of the test-validated regulator model
                             % (Manimaran & Hiremath 2018); 0.50 = conservative Swagelok RHPS sizing rule

%% 3. INPUTS - PILOT REGULATOR SIZE
Pr_set_barg      = 5;        % regulated pressure setting        [bar(g)]
d_pilot_seat_mm  = 2.0;      % pilot seat diameter (outer sealing diameter) [mm]
x_pilot_max_mm   = 0.5;      % pilot maximum stroke              [mm]
D_pilot_pist_mm  = 20;       % pilot sensing piston diameter     [mm]
k_pilot_Nmm      = 30;       % pilot spring rate                 [N/mm]
m_pilot_g        = 30;       % pilot moving mass                 [g]
d_bleed_mm       = 0.8;      % bleed orifice diameter (piston chamber to ambient) [mm]
seat_angle_deg   = 45;       % seat angle, pilot and main valve  [deg]

%% 4. INPUTS - MAIN VALVE SIZE
d_main_seat_mm   = 40;       % main valve seat diameter (outer sealing diameter) [mm]
D_main_pist_mm   = 60;       % big piston diameter               [mm]
x_main_max_mm    = 10;       % big piston stroke: 0 = no pressure, valve fully open; full stroke = valve closed [mm]
k_main_Nmm       = 70;       % main spring rate                  [N/mm]
x_main_design_mm = 2;        % DESIGN POINT: piston displacement (spring compression from rest) at the
                             % regulated pressure [mm]; valve opening = stroke - this value
m_main_g         = 500;      % main valve moving mass            [g]
V_chamber_cm3    = 50;       % piston chamber volume, piston at rest [cm3]
V_outlet_L       = 5;        % volume at the main valve outlet   [L]

%% 5. INPUTS - SIMULATION
zeta             = 0.7;      % damping ratio of the moving parts [-]
t_end_s          = 2.0;      % simulated time                    [s]
dt_s             = 1e-5;     % time step                         [s]
t_print_s        = [0.02 0.05 0.1 0.15 0.2 0.3 0.5 1.0 2.0];   % times printed in the table [s]

%% ===================== END OF INPUTS ======================================

%% 6. INPUT CHECKS AND UNIT CONVERSION TO SI (do not edit)
% Every row: a condition that must be true, and the message shown if it is not.
checks = {
    (P1_barg > 0),                                        'Inlet pressure must be > 0 bar(g).'
    (T1_K > 0 && T_start_K > 0),                          'Temperatures must be > 0 K.'
    (m_design_kgs > 0),                                   'Design flow must be > 0.'
    (t_ramp_s >= 0),                                      'Inlet pressure rise time cannot be negative.'
    (gas_R > 0 && gas_gamma > 1 && P_atm_bar > 0),        'Gas constant and ambient pressure must be > 0 and the ratio of specific heats > 1.'
    (any(flow_coeff_law == [1 2 3])),                     'flow_coeff_law must be 1, 2 or 3.'
    (Cd_constant > 0 && Cd_constant <= 1),                'Cd_constant must be > 0 and at most 1.'
    (Pr_set_barg > 0 && Pr_set_barg < P1_barg),           'The regulated pressure setting must be > 0 and below the inlet pressure.'
    (d_pilot_seat_mm > 0 && x_pilot_max_mm > 0),          'Pilot seat diameter and pilot stroke must be > 0.'
    (D_pilot_pist_mm > d_pilot_seat_mm),                  'Pilot piston diameter must be larger than the pilot seat diameter.'
    (k_pilot_Nmm > 0 && m_pilot_g > 0),                   'Pilot spring rate and pilot mass must be > 0.'
    (d_bleed_mm >= 0),                                    'Bleed orifice diameter cannot be negative.'
    (seat_angle_deg > 0 && seat_angle_deg <= 90),         'Seat angle must be between 0 and 90 deg (90 = flat seat).'
    (d_main_seat_mm > 0 && D_main_pist_mm > 0 && x_main_max_mm > 0), 'Main seat diameter, piston diameter and stroke must be > 0.'
    (k_main_Nmm > 0 && m_main_g > 0),                     'Main spring rate and main valve mass must be > 0.'
    (x_main_design_mm >= 0 && x_main_design_mm < x_main_max_mm), ...
        'The piston design displacement must be at least 0 and smaller than the piston stroke (at full stroke the valve is closed).'
    (V_chamber_cm3 > 0 && V_outlet_L > 0),                'Volumes must be > 0.'
    (zeta >= 0 && t_end_s > 0 && dt_s > 0),               'Damping ratio cannot be negative; simulated time and time step must be > 0.'
    };
bad = checks(~[checks{:,1}], 2);
if ~isempty(bad)
    error('Check the inputs:\n  - %s', strjoin(bad', sprintf('\n  - ')));
end

R     = gas_R;   g = gas_gamma;
Pamb  = P_atm_bar*1e5;                    % [Pa]
P1    = P1_barg*1e5 + Pamb;               % [Pa abs]
T1    = T1_K;
Prset = Pr_set_barg*1e5 + Pamb;           % [Pa abs]
d_ps  = d_pilot_seat_mm/1e3;   xp_max = x_pilot_max_mm/1e3;
A_pp  = pi*(D_pilot_pist_mm/1e3)^2/4;     % pilot sensing piston area [m2]
A_ps  = pi*d_ps^2/4;                      % pilot seat area [m2]
k_p   = k_pilot_Nmm*1e3;       m_p = m_pilot_g/1e3;
A_b   = pi*(d_bleed_mm/1e3)^2/4;          % bleed orifice area [m2]
d_ms  = d_main_seat_mm/1e3;    xm_max = x_main_max_mm/1e3;
A_mp  = pi*(D_main_pist_mm/1e3)^2/4;      % big piston area [m2]
A_bore = pi*d_ms^2/4;                     % main seat bore area [m2]
k_m   = k_main_Nmm*1e3;        m_m = m_main_g/1e3;     xm_des = x_main_design_mm/1e3;
V_c0  = V_chamber_cm3/1e6;     V_out = V_outlet_L/1e3;
dt    = min(dt_s, 0.1/max(sqrt(k_p/m_p), sqrt(k_m/m_m)));   % time step, reduced if the springs are too stiff for it

%% 7. GAS FLOW FUNCTIONS
f     = sqrt(g)*(2/(g+1))^((g+1)/(2*(g-1)));
pcr   = (2/(g+1))^(g/(g-1));              % critical pressure ratio (choked below this)
Nden  = (g-1)/2*(2/(g+1))^((g+1)/(g-1));
Nf    = @(r) (r <= pcr) + (r > pcr).*sqrt(max(r.^(2/g) - r.^((g+1)/g), 0)/Nden);
% mass flow through area A from pressure Pu (temperature Tu) to pressure Pd; zero if Pu <= Pd
% flow coefficient Cd as a function of the pressure ratio r = Pd/Pu
if flow_coeff_law == 1
    Cdf = @(r) 1 - 0.7*r;                                  % thesis rule
elseif flow_coeff_law == 2
    Cdf = @(r) Cd_constant + 0*r;                          % constant value
else
    Cdf = @(r) 0.8414 - 0.1002*r + 0.8415*r.^2 - 3.9*r.^3 + 4.6001*r.^4 - 1.6827*r.^5;   % Perry, sharp-edged orifice
end
mdot  = @(A, Pu, Pd, Tu) (Pu > Pd) .* Cdf(min(Pd./Pu,1)) .* A * f .* Nf(min(Pd./Pu,1)) .* Pu ./ sqrt(R*Tu);
s     = sind(seat_angle_deg);   sc = sind(seat_angle_deg)*cosd(seat_angle_deg);
Acone = @(x, d) pi*max(x,0).*s.*(d - max(x,0)*sc);     % conical seat flow area

%% 8. SETTINGS WORKED OUT FROM THE INPUTS
% --- pilot spring preload: the adjusting screw is set so that the regulator
%     holds Pr_set while it feeds the bleed flow
m_bleed_set = mdot(A_b, Prset, Pamb, T1);                 % bleed flow at the set pressure
m_pilot_max = mdot(min(Acone(xp_max, d_ps), A_ps), P1, Prset, T1);   % most the pilot can feed at its full stroke
if m_pilot_max <= m_bleed_set
    error(['Pilot regulator too small to hold %.2f bar(g): fully open it feeds %.3f g/s, but the bleed orifice takes %.3f g/s. ' ...
           'Increase the pilot seat diameter or pilot stroke, or reduce the bleed orifice.'], Pr_set_barg, m_pilot_max*1e3, m_bleed_set*1e3);
end
xp_set = 0;                                               % pilot stroke needed for that flow
for it = 1:60                                             % bisection on the stroke
    if it == 1, lo = 0; hi = xp_max; end
    xp_set = (lo + hi)/2;
    if mdot(Acone(xp_set, d_ps), P1, Prset, T1) > m_bleed_set, hi = xp_set; else, lo = xp_set; end
end
F_p0 = (Prset - Pamb)*A_pp + (P1 - Prset)*A_ps + k_p*xp_set;   % pilot spring force at closed position

% --- main spring preload: set so that the piston sits at its design
%     displacement when the regulated pressure acts on it
F_m0 = (Prset - Pamb)*A_mp - k_m*xm_des;                   % main spring preload (no pressure, valve fully open)
open_des = xm_max - xm_des;                                % valve opening at the design point
if F_m0 < 0
    error(['Piston too small or spring too stiff: %.2f bar(g) on the piston gives %.0f N, ' ...
           'but the spring needs %.0f N to be compressed by %.2f mm. ' ...
           'Increase the piston diameter, reduce the spring rate or reduce the design displacement.'], ...
           Pr_set_barg, (Prset - Pamb)*A_mp, k_m*xm_des, xm_des*1e3);
end

% --- load: orifice to ambient that passes the design flow at the design displacement
A_main_design = min(Acone(open_des, d_ms), A_bore);        % main valve flow area at the design point
m_main_max = mdot(A_main_design, P1, pcr*P1, T1);          % most that opening can pass (choked)
if m_main_max < m_design_kgs
    error(['Main valve opening too small at the design point: %.2f mm opening (%.0f mm2) passes at most %.3f kg/s ' ...
           'at %.2f bar(g) inlet, but the design flow is %.3f kg/s. Increase the seat diameter or piston stroke, ' ...
           'reduce the design displacement, raise the inlet pressure or lower the design flow.'], ...
           open_des*1e3, A_main_design*1e6, m_main_max, P1_barg, m_design_kgs);
end
lo = Pamb; hi = P1;                                       % find the outlet pressure P2
for it = 1:60
    P2_design = (lo + hi)/2;
    if mdot(A_main_design, P1, P2_design, T1) > m_design_kgs, lo = P2_design; else, hi = P2_design; end
end
r_load = Pamb/P2_design;
A_load = m_design_kgs*sqrt(R*T1) / (Cdf(r_load)*f*Nf(r_load)*P2_design);   % load orifice area

% --- damping from the damping ratio
c_p = 2*zeta*sqrt(k_p*m_p);   c_m = 2*zeta*sqrt(k_m*m_m);

law_txt = {'thesis rule Cd = 1 - 0.7*Pd/Pu', sprintf('constant Cd = %.2f', Cd_constant), 'Perry rule (sharp-edged orifice)'};
fprintf('================ SETTINGS FROM THE INPUTS ================\n');
fprintf('Flow coefficient: %s\n', law_txt{flow_coeff_law});
fprintf('Pilot spring force at closed position   %8.1f N   (set for %.2f bar(g) with bleed flow %.3f g/s)\n', F_p0, Pr_set_barg, m_bleed_set*1e3);
fprintf('Main spring preload (valve fully open)  %8.1f N   (piston at %.2f mm of %.2f mm at %.2f bar(g))\n', ...
        F_m0, xm_des*1e3, xm_max*1e3, Pr_set_barg);
fprintf('Valve starts to close / is fully closed at  %.2f / %.2f bar(g) on the big piston\n', F_m0/A_mp/1e5, (F_m0 + k_m*xm_max)/A_mp/1e5);
fprintf('Main valve at the design point          %8.2f mm opening, flow area %.1f mm2\n', open_des*1e3, A_main_design*1e6);
fprintf('Load orifice (effective area)           %8.1f mm2  (passes %.3f kg/s at outlet %.2f bar(g))\n', A_load*1e6, m_design_kgs, (P2_design-Pamb)/1e5);

%% 9. DYNAMIC SIMULATION (step by step in time)
N  = round(t_end_s/dt) + 1;
t  = (0:N-1)'*dt;
if t_ramp_s > 0
    P1t = Pamb + (P1 - Pamb)*min(t/t_ramp_s, 1);          % inlet pressure ramp
else
    P1t = P1*ones(N,1);                                   % inlet pressure applied at once
end
[Pr_h, Tr_h, P2_h, T2_h, xp_h, xm_h, mp_h, mb_h, mm_h, ml_h] = deal(zeros(N,1));

% initial state: everything at ambient pressure, valves at rest
Pr = Pamb;  Tr = T_start_K;      % piston chamber (regulated pressure)
P2 = Pamb;  T2 = T_start_K;      % main valve outlet volume
xp = xp_max; vp = 0;             % pilot is held open by its spring
xm = 0;      vm = 0;             % big piston at rest: the spring holds the main valve fully open

for n = 1:N
    Pin = P1t(n);

    % STEP 1 - pilot regulator: flow from the inlet into the piston chamber
    A_pil = min(Acone(xp, d_ps), A_ps);
    m_pil = mdot(A_pil, Pin, Pr, T1);

    % STEP 2 - bleed orifice: flow from the piston chamber to ambient
    m_bl  = mdot(A_b, Pr, Pamb, Tr);

    % STEP 3 - piston chamber: pressure and temperature (volume grows with the main stroke)
    Vc  = V_c0 + A_mp*xm;
    dPr = (g*R*(T1*m_pil - Tr*m_bl) - g*Pr*A_mp*vm) / Vc;
    dTr = R*Tr^2/(Vc*Pr)*((g*T1/Tr - 1)*m_pil - (g - 1)*m_bl) - (g - 1)*Tr*A_mp*vm/Vc;

    % STEP 4 - pilot regulator force balance (positive = opening)
    Fp  = F_p0 - k_p*xp - (Pr - Pamb)*A_pp - (Pin - Pr)*A_ps - c_p*vp;

    % STEP 5 - big piston force balance (positive = compressing the spring = closing the valve)
    Fm  = (Pr - Pamb)*A_mp - F_m0 - k_m*xm - c_m*vm;

    % STEP 6 - main valve: flow from the inlet to the outlet volume
    A_mv   = min(Acone(xm_max - xm, d_ms), A_bore);       % valve opening = stroke - piston displacement
    m_main = mdot(A_mv, Pin, P2, T1);

    % STEP 7 - load: flow from the outlet volume to the consumer
    m_load = mdot(A_load, P2, Pamb, T2);

    % STEP 8 - outlet volume: pressure and temperature
    dP2 = g*R/V_out*(T1*m_main - T2*m_load);
    dT2 = R*T2^2/(V_out*P2)*((g*T1/T2 - 1)*m_main - (g - 1)*m_load);

    % save
    Pr_h(n) = Pr;  Tr_h(n) = Tr;  P2_h(n) = P2;  T2_h(n) = T2;  xp_h(n) = xp;  xm_h(n) = xm;
    mp_h(n) = m_pil;  mb_h(n) = m_bl;  mm_h(n) = m_main;  ml_h(n) = m_load;

    % STEP 9 - go one time step forward (Euler)
    Pr = max(Pr + dPr*dt, 0.05*Pamb);   Tr = max(Tr + dTr*dt, 50);    % (pressure and temperature stay positive)
    P2 = max(P2 + dP2*dt, 0.05*Pamb);   T2 = max(T2 + dT2*dt, 50);
    vp = vp + Fp/m_p*dt;   xp = xp + vp*dt;
    vm = vm + Fm/m_m*dt;   xm = xm + vm*dt;
    if xp < 0,      xp = 0;      vp = max(vp, 0);  end    % pilot on its seat
    if xp > xp_max, xp = xp_max; vp = min(vp, 0);  end    % pilot on its stop
    if xm < 0,      xm = 0;      vm = max(vm, 0);  end    % piston at rest, main valve fully open
    if xm > xm_max, xm = xm_max; vm = min(vm, 0);  end    % end of stroke, main valve closed
end

%% 10. RESULTS - TABLE IN TIME
bg = @(P) (P - Pamb)/1e5;
fprintf('\n================ STEP-BY-STEP RESULTS IN TIME ================\n');
fprintf('  time   inlet P1 | pilot    pilot    bleed  | regulated  chamber | piston   main     | outlet   outlet   load\n');
fprintf('                  | stroke   flow     flow   | pressure   temp.   | displ.   flow     | P2       temp.    flow\n');
fprintf('   s     bar(g)   | mm       g/s      g/s    | bar(g)     K       | mm       kg/s     | bar(g)   K        kg/s\n');
for q = 1:numel(t_print_s)
    n = min(round(t_print_s(q)/dt) + 1, N);
    fprintf('%6.3f  %7.3f   | %6.4f  %7.3f  %6.3f  | %7.3f   %6.1f   | %6.3f  %7.4f   | %6.3f   %6.1f   %6.4f\n', ...
        t(n), bg(P1t(n)), xp_h(n)*1e3, mp_h(n)*1e3, mb_h(n)*1e3, bg(Pr_h(n)), Tr_h(n), ...
        xm_h(n)*1e3, mm_h(n), bg(P2_h(n)), T2_h(n), ml_h(n));
end

%% 11. RESULTS - FINAL STATE, STEP BY STEP
n = N;
r_pil = Pr_h(n)/P1t(n);  r_mv = P2_h(n)/P1t(n);  r_bl = Pamb/Pr_h(n);  r_ld = Pamb/P2_h(n);
ch = {'not choked', 'choked'};
fprintf('\n================ FINAL STATE AT t = %.2f s ================\n', t(n));
fprintf('1. INLET              P1 = %.3f bar(g), T1 = %.1f K, total flow %.4f kg/s\n', bg(P1t(n)), T1, mm_h(n) + mp_h(n));
fprintf('2. PILOT REGULATOR    stroke %.4f mm, flow area %.4f mm2, P ratio %.3f (%s), flow %.3f g/s\n', ...
        xp_h(n)*1e3, Acone(xp_h(n), d_ps)*1e6, r_pil, ch{(r_pil <= pcr)+1}, mp_h(n)*1e3);
fprintf('3. PISTON CHAMBER     regulated pressure Pr = %.3f bar(g) (set %.2f), temperature %.1f K\n', bg(Pr_h(n)), Pr_set_barg, Tr_h(n));
fprintf('4. BLEED ORIFICE      P ratio %.3f (%s), flow %.3f g/s to ambient\n', r_bl, ch{(r_bl <= pcr)+1}, mb_h(n)*1e3);
fprintf('5. BIG PISTON         pressure force %.1f N, spring force %.1f N, displacement %.3f mm (design %.3f, stroke %.3f)\n', ...
        (Pr_h(n) - Pamb)*A_mp, F_m0 + k_m*xm_h(n), xm_h(n)*1e3, xm_des*1e3, xm_max*1e3);
fprintf('6. MAIN VALVE         opening %.3f mm, flow area %.1f mm2, P ratio %.3f (%s), flow %.4f kg/s\n', ...
        (xm_max - xm_h(n))*1e3, min(Acone(xm_max - xm_h(n), d_ms), A_bore)*1e6, r_mv, ch{(r_mv <= pcr)+1}, mm_h(n));
fprintf('7. OUTLET             P2 = %.3f bar(g), T2 = %.1f K, flow to the load %.4f kg/s (%s)\n', ...
        bg(P2_h(n)), T2_h(n), ml_h(n), ch{(r_ld <= pcr)+1});
fprintf('\nREGULATOR OUTPUT      Pr = %.3f bar(g), flow %.3f g/s\n', bg(Pr_h(n)), mp_h(n)*1e3);
fprintf('MAIN VALVE OUTPUT     P2 = %.3f bar(g), flow %.4f kg/s\n', bg(P2_h(n)), ml_h(n));
% --- is the result steady? compare the last 10 % of the time with the 10 % before it
w1 = t >= 0.9*t_end_s;   w0 = t >= 0.8*t_end_s & t < 0.9*t_end_s;
ripple = [max(Pr_h(w1)) - min(Pr_h(w1)), max(P2_h(w1)) - min(P2_h(w1))]/1e5;        % [bar]
drift  = abs([mean(Pr_h(w1)) - mean(Pr_h(w0)), mean(P2_h(w1)) - mean(P2_h(w0))])/1e5; % [bar]
fprintf('Last 10 %% of the time: ripple of regulated / outlet pressure %.4f / %.4f bar, drift %.4f / %.4f bar\n', ripple, drift);
i_des = find(abs(xm_h - xm_des) <= 0.02*xm_max & t > t_ramp_s, 1);
if abs(xm_h(n) - xm_des) > 0.02*xm_max
    fprintf('Big piston is NOT at its design displacement at the end (%.3f mm instead of %.3f mm).\n', xm_h(n)*1e3, xm_des*1e3);
else
    fprintf('Big piston first reaches its design displacement after %.3f s.\n', t(i_des));
end
if max(ripple) < 0.01 && max(drift) < 0.005
    fprintf('RESULT: steady - the values above are the final operating point.\n');
elseif max(drift) >= 0.5*max(ripple)
    fprintf('RESULT: NOT SETTLED YET - pressures are still changing at the end. Increase t_end_s.\n');
else
    fprintf(['RESULT: OSCILLATING - the values above are not a steady operating point. Try a larger piston chamber volume,\n' ...
             '        more damping (zeta), a softer pilot spring or a smaller pilot seat.\n']);
end
if dt < dt_s
    fprintf('Note: the time step was reduced from %.1e to %.1e s because of the stiff springs.\n', dt_s, dt);
end

%% 12. PLOTS
figure('Name', 'Pilot-operated valve dynamics', 'Position', [100 100 800 900]);
subplot(4,1,1);
plot(t, bg(P1t), 'k', t, bg(Pr_h), 'r', t, bg(P2_h), 'b'); grid on; ylabel('pressure (bar(g))');
legend('inlet P1', 'regulated Pr', 'outlet P2', 'Location', 'southeast');
title('Pilot-operated main valve: start-up');
subplot(4,1,2);
plot(t, xm_h*1e3, 'b', t, (xm_max - xm_h)*1e3, 'k--', t, xp_h*1e3*10, 'r'); grid on; ylabel('displacement (mm)');
legend('big piston (spring compression)', 'main valve opening', 'pilot x 10', 'Location', 'east');
subplot(4,1,3);
plot(t, mm_h, 'b', t, ml_h, 'k--', t, mp_h*100, 'r', t, mb_h*100, 'm:'); grid on; ylabel('flow (kg/s)');
legend('main valve', 'to load', 'pilot x 100', 'bleed x 100', 'Location', 'southeast');
subplot(4,1,4);
plot(t, Tr_h, 'r', t, T2_h, 'b'); grid on; ylabel('temperature (K)'); xlabel('Time (s)');
legend('piston chamber', 'outlet', 'Location', 'southeast');
