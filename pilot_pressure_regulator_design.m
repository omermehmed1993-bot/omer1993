%% PILOT-OPERATED PRESSURE REGULATOR - SIZING CODE
%
% Purely mechanical pilot-operated regulator (no voice coil, no electronic
% controller). Fill in the INPUTS (sections 1 - 3) and run. The script sizes
% every part and prints a design report; optionally it simulates the
% regulator in time to check accuracy and stability.
%
% Layout (standard pilot-operated regulator, piston sensing):
%
%   INLET P1 ---+------------> MAIN VALVE (poppet) ------------> OUTLET P2
%               |                    ^ opened by MAIN PISTON          |
%               |                    |  (P_L on top, P2 below,        |
%               |                    |   main spring closes)          |
%               +--> PILOT VALVE --> LOADING CHAMBER P_L --> BLEED ---+
%                     ^                                    ORIFICE
%                     | opened by PILOT SPRING, closed by
%                     | outlet pressure P2 on the PILOT PISTON
%
%  - Outlet pressure falls -> pilot opens -> P_L rises -> main valve opens.
%  - Outlet pressure rises -> pilot closes -> P_L bleeds to the outlet
%    through the bleed orifice -> main spring closes the main valve.
%
% Sized parts: ports, main seat + stroke, main piston, main spring,
% bleed orifice, pilot seat + stroke, pilot piston, pilot spring,
% spring wire / coil geometry; plus droop and supply-pressure effect.
%
% Flow through any orifice: m = Cd*A*f(g)*N*Pu/sqrt(R*T), Cd from input "flow_coeff_law"
% Conical seat flow area:   A = pi*x*sin(th)*(d - x*sin(th)*cos(th)),
%                           d = seat diameter = OUTER (large) sealing diameter of the poppet
% Runs in MATLAB or GNU Octave, no toolboxes needed.

clear; clc; close all;

%% ======================= INPUTS (edit only here) =========================

%% 1. INPUTS - REQUIREMENTS
gas_R            = 287;      % gas constant              [J/(kg K)]  air 287, N2 297, He 2077
gas_gamma        = 1.4;      % ratio of specific heats   [-]         air 1.4, N2 1.4, He 1.667
T_inlet_C        = 20;       % gas temperature           [degC]
P_atm_bar        = 1.01325;  % ambient pressure          [bar(a)]

P1_nominal_barg  = 10;       % nominal inlet pressure    [bar(g)]
P1_minimum_barg  = 8;        % minimum inlet pressure    [bar(g)]   main valve is sized here
P1_maximum_barg  = 12;       % maximum inlet pressure    [bar(g)]   pilot spring checked here
P2_set_barg      = 6;        % outlet set pressure       [bar(g)]
P2_adj_min_barg  = 4;        % pilot spring adjustment range, lowest  [bar(g)]
P2_adj_max_barg  = 8;        % pilot spring adjustment range, highest [bar(g)]
Q_design_Nm3h    = 500;      % design flow               [Nm3/h]    (0 degC, 1.01325 bar)
droop_bar        = 0.10;     % allowed outlet drop, no flow -> full flow [bar]

%% 2. INPUTS - DESIGN CHOICES (typical values)
v_port_max_ms    = 30;       % max gas velocity in the ports        [m/s]
seat_angle_deg   = 45;       % seat angle, main and pilot valve     [deg]
flow_coeff_law   = 2;        % flow coefficient Cd of every opening:
                             %   1 = thesis rule      Cd = 1 - 0.7*Pd/Pu
                             %   2 = constant value   Cd = Cd_constant   (default: fits measured regulator data best)
                             %   3 = Perry rule for a sharp-edged orifice (0.84 choked ... 0.60 at no pressure drop);
                             %       this is the variable-Cq option of the Amesim pneumatic library
Cd_constant      = 0.70;     % used only with law 2 [-]. 0.70 = value of the test-validated regulator model
                             % (Manimaran & Hiremath 2018); 0.50 = conservative Swagelok RHPS sizing rule
stroke_to_seat   = 0.15;     % main stroke / main seat diameter at full flow [-]
piston_to_seat   = 2.0;      % main piston diameter / main seat diameter     [-]
dP_crack_bar     = 0.2;      % loading - outlet pressure when main valve starts to open [bar]
dP_full_bar      = 1.0;      % loading - outlet pressure at full main valve opening    [bar]
d_bleed_mm       = 1.0;      % bleed orifice diameter               [mm]
d_pilot_seat_mm  = 2.0;      % pilot seat diameter (outer sealing diameter) [mm]
D_pilot_pist_mm  = 25;       % pilot piston diameter                [mm]
G_spring_GPa     = 79.3;     % spring material shear modulus        [GPa]  (steel)
tau_allow_MPa    = 600;      % spring allowed shear stress          [MPa]
n_active_coils   = 6;        % active coils of each spring          [-]

%% 3. INPUTS - DESIGN CHECK SIMULATION (optional)
run_check_sim    = 1;        % 1 = run the time simulation check, 0 = sizing only
m_main_g         = 250;      % main poppet + piston moving mass     [g]
m_pilot_g        = 30;       % pilot plug + piston moving mass      [g]
zeta             = 0.7;      % damping ratio of the moving parts    [-]
V_outlet_L       = 5;        % downstream volume (pipe / receiver)  [L]
V_loading_cm3    = 100;      % loading chamber volume, main closed  [cm3]  (below ~40 cm3 this example oscillates)

%% ===================== END OF INPUTS ======================================

%% 4. INPUT CHECKS AND UNIT CONVERSION TO SI (do not edit)
% Every row: a condition that must be true, and the message shown if it is not.
checks = {
    gas_R > 0 && gas_gamma > 1,                         'Gas constant must be > 0 and the ratio of specific heats > 1.'
    T_inlet_C > -273.15 && P_atm_bar > 0,               'Temperature must be above -273.15 degC and ambient pressure > 0.'
    P1_minimum_barg <= P1_nominal_barg && P1_nominal_barg <= P1_maximum_barg, ...
                                                        'Inlet pressures must be in the order minimum <= nominal <= maximum.'
    P2_set_barg > 0,                                    'Outlet set pressure must be > 0 bar(g).'
    P2_adj_min_barg <= P2_set_barg && P2_set_barg <= P2_adj_max_barg, ...
                                                        'Outlet set pressure must lie inside the pilot spring adjustment range.'
    Q_design_Nm3h > 0,                                  'Design flow must be > 0.'
    droop_bar > 0 && droop_bar < P2_set_barg,           'Droop must be > 0 and smaller than the outlet set pressure.'
    v_port_max_ms > 0,                                  'Port velocity must be > 0.'
    seat_angle_deg > 0 && seat_angle_deg <= 90,         'Seat angle must be between 0 and 90 deg (90 = flat seat).'
    stroke_to_seat > 0 && stroke_to_seat <= 0.25,       'Main stroke / seat diameter must be > 0 and at most 0.25 (above that the seat bore limits the flow).'
    piston_to_seat > 0,                                 'Main piston / seat diameter ratio must be > 0.'
    dP_crack_bar >= 0 && dP_full_bar > dP_crack_bar,    'Loading pressure at full opening must be higher than at cracking (dP_full_bar > dP_crack_bar >= 0).'
    P1_minimum_barg > P2_set_barg - droop_bar + dP_full_bar, ...
        sprintf(['Minimum inlet pressure too low. The pilot needs P1 min > P2 set - droop + dP_full = %.2f bar(g). ' ...
                 'Raise P1 min, lower the outlet pressure or reduce dP_full_bar.'], P2_set_barg - droop_bar + dP_full_bar)
    d_bleed_mm > 0 && d_pilot_seat_mm > 0,              'Bleed orifice and pilot seat diameters must be > 0.'
    D_pilot_pist_mm > d_pilot_seat_mm,                  'Pilot piston diameter must be larger than the pilot seat diameter.'
    G_spring_GPa > 0 && tau_allow_MPa > 0 && n_active_coils >= 1, 'Spring data must be > 0 and active coils >= 1.'
    any(flow_coeff_law == [1 2 3]),                     'flow_coeff_law must be 1, 2 or 3.'
    Cd_constant > 0 && Cd_constant <= 1,                'Cd_constant must be > 0 and at most 1.'
    m_main_g > 0 && m_pilot_g > 0 && zeta >= 0 && V_outlet_L > 0 && V_loading_cm3 > 0, ...
                                                        'Masses and volumes must be > 0 and the damping ratio >= 0.'
    };
bad = checks(~[checks{:,1}], 2);
if ~isempty(bad)
    error('Check the inputs:\n  - %s', strjoin(bad', sprintf('\n  - ')));
end

R        = gas_R;
g        = gas_gamma;
T        = T_inlet_C + 273.15;          % [K]
Pamb     = P_atm_bar * 1e5;             % [Pa]
P1_nom   = P1_nominal_barg * 1e5;       % [Pa gauge]
P1_min   = P1_minimum_barg * 1e5;
P1_max   = P1_maximum_barg * 1e5;
P2_set   = P2_set_barg * 1e5;
P2_adj   = [P2_adj_min_barg P2_adj_max_barg] * 1e5;
Q        = Q_design_Nm3h;               % [Nm3/h]
droop    = droop_bar * 1e5;             % [Pa]
v_port   = v_port_max_ms;
th_deg   = seat_angle_deg;
x_d_main = stroke_to_seat;
D_ratio  = piston_to_seat;
dP_crack = dP_crack_bar * 1e5;
dP_full  = dP_full_bar * 1e5;
d_bleed  = d_bleed_mm / 1e3;            % [m]
d_pseat  = d_pilot_seat_mm / 1e3;
D_ppist  = D_pilot_pist_mm / 1e3;
G_spring = G_spring_GPa * 1e9;          % [Pa]
tau_all  = tau_allow_MPa * 1e6;
n_active = n_active_coils;
mass_main  = m_main_g / 1e3;            % [kg]
mass_pilot = m_pilot_g / 1e3;
V_out    = V_outlet_L / 1e3;            % [m3]
V_L0     = V_loading_cm3 / 1e6;

%% 5. GAS FLOW FUNCTIONS
f    = sqrt(g) * (2/(g+1))^((g+1)/(2*(g-1)));
pcr  = (2/(g+1))^(g/(g-1));                            % critical pressure ratio
Nden = (g-1)/2 * (2/(g+1))^((g+1)/(g-1));
Nf   = @(r) (r <= pcr) + (r > pcr) .* sqrt(max(r.^(2/g) - r.^((g+1)/g), 0) / Nden);
% flow coefficient Cd as a function of the pressure ratio r = Pd/Pu
if flow_coeff_law == 1
    Cdf = @(r) 1 - 0.7*r;                                  % thesis rule
elseif flow_coeff_law == 2
    Cdf = @(r) Cd_constant + 0*r;                          % constant value
else
    Cdf = @(r) 0.8414 - 0.1002*r + 0.8415*r.^2 - 3.9*r.^3 + 4.6001*r.^4 - 1.6827*r.^5;   % Perry, sharp-edged orifice
end
mdot = @(A, Pu, Pd) Cdf(Pd./Pu) .* A * f .* Nf(Pd./Pu) .* Pu / sqrt(R*T);
Areq = @(m, Pu, Pd) m * sqrt(R*T) ./ (Cdf(Pd./Pu) * f .* Nf(Pd./Pu) .* Pu);
s    = sind(th_deg);  sc = sind(th_deg)*cosd(th_deg);
Aseat  = @(x, d) pi * max(x,0) .* s .* (d - max(x,0)*sc);
if sc < 1e-9                                              % flat seat (90 deg): A = pi*d*x
    stroke = @(A, d) A ./ (pi*d*s);
else                                                      % cone: solve the area formula for the stroke
    stroke = @(A, d) (d - sqrt(d.^2 - 4*sc*A/(pi*s))) / (2*sc);
end

%% 6. DESIGN CALCULATION
% --- absolute pressures and flow
P1n = P1_nom + Pamb;  P1l = P1_min + Pamb;  P1h = P1_max + Pamb;
P2s = P2_set + Pamb;                       % outlet at lock-up (no flow)
P2f = P2s - droop;                         % outlet at full flow
rhoN = Pamb/(R*273.15);
m    = Q * rhoN / 3600;                    % design mass flow [kg/s]

% --- ports (velocity limit, worst case = lowest pressure)
d_in  = sqrt(4*m/(P1l/(R*T))/v_port/pi);
d_out = sqrt(4*m/(P2f/(R*T))/v_port/pi);

% --- main valve: sized at the MINIMUM inlet pressure and full flow
PLf    = P2f + dP_full;                    % loading pressure at full opening
A_main = Areq(m, P1l, P2f);                % required flow area
d_main = sqrt(A_main / (pi*x_d_main*s*(1 - x_d_main*sc)));   % seat diameter
x_main = stroke(A_main, d_main);           % stroke at full flow, P1 min
x_main_nom = stroke(Areq(m, P1n, P2f), d_main);              % stroke at P1 nominal
x_main_max = d_main/4;                     % mechanical stop (curtain area = seat area)
D_main = D_ratio * d_main;                 % main piston diameter
A_mp   = pi*D_main^2/4;
F_m0   = dP_crack * A_mp;                  % main spring preload (valve closed)
k_main = (dP_full - dP_crack) * A_mp / x_main;   % main spring rate

% --- bleed orifice and pilot valve (pilot feeds the bleed flow)
A_b    = pi*d_bleed^2/4;
m_b    = mdot(A_b, PLf, P2f);              % bleed (= pilot) flow at full opening
m_bcr  = mdot(A_b, P2s + dP_crack, P2s);   % bleed flow when main valve cracks
A_pilot = Areq(m_b, P1l, PLf);             % pilot flow area (P1 min, worst case)
A_pilot_max = min(Aseat(d_pseat/4, d_pseat), pi*d_pseat^2/4);   % most the pilot seat can give
if A_pilot > A_pilot_max
    error(['Pilot seat too small: it must pass the bleed flow through %.3f mm2, but a %.2f mm seat gives at most %.3f mm2. ' ...
           'Increase the pilot seat diameter or reduce the bleed orifice.'], A_pilot*1e6, d_pseat*1e3, A_pilot_max*1e6);
end
x_pilot = stroke(A_pilot, d_pseat);        % pilot stroke at full flow

% --- pilot piston and pilot spring
A_pp   = pi*D_ppist^2/4;                   % pilot sensing area
A_ps   = pi*d_pseat^2/4;                   % pilot seat area (inlet P pushes plug closed)
k_pilot = droop * A_pp / x_pilot;          % pilot spring rate for the allowed droop
F_p0   = P2_set*A_pp + (P1n - P2s)*A_ps;   % pilot spring force at set point (closed)
SPE    = A_ps / A_pp;                      % supply pressure effect [Pa outlet / Pa inlet]

% --- checks
dP_min_needed = dP_full + droop;           % P1 - P2 needed for full opening (excl. valve loss)
ok_loading = (P1l - P2f) > dP_full;
ok_stroke  = x_main <= x_main_max;
ok_seat_p  = x_pilot <= d_pseat/4;

% --- helical spring geometry (wire d, coil D) for both springs
%     rate:   k   = G d^4 / (8 D^3 n)
%     stress: tau = 8 F D Kw / (pi d^3),  Kw = Wahl factor
sp(1).name = 'Main spring';   sp(1).k = k_main;
sp(1).F    = [F_m0, F_m0 + k_main*x_main_max];                   % preload, max force
sp(2).name = 'Pilot spring';  sp(2).k = k_pilot;
sp(2).F    = [F_p0, P2_adj(2)*A_pp + (P1h - P2_adj(2) - Pamb)*A_ps + k_pilot*d_pseat/4];
C_min = 4;                                                       % smallest spring index that can be wound
for j = 1:2
    sp(j).found = false;
    for d = 0.2e-3:0.05e-3:40e-3                                % try wire sizes, smallest first
        D  = (G_spring*d^4 / (8*n_active*sp(j).k))^(1/3);         % coil diameter from rate
        C  = D/d;
        if C < C_min, continue; end                              % coil too tight for this wire: try a thicker wire
        Kw = (4*C-1)/(4*C-4) + 0.615/C;
        tau = 8*sp(j).F(2)*D*Kw / (pi*d^3);
        if tau <= tau_all, sp(j).found = true; break; end
    end
    if ~sp(j).found
        error('%s: no wire up to 40 mm gives the rate %.1f N/mm within the stress and index limits. Change the active coils or the spring rate.', ...
              sp(j).name, sp(j).k/1e3);
    end
    sp(j).d = d;  sp(j).D = D;  sp(j).C = C;  sp(j).tau = tau;
    sp(j).n_total  = n_active + 2;                               % closed + ground ends
    sp(j).L_solid  = sp(j).n_total * d;
    sp(j).L_free   = sp(j).L_solid + 1.15*sp(j).F(2)/sp(j).k;    % 15 % clash allowance
    sp(j).L_inst   = sp(j).L_free - sp(j).F(1)/sp(j).k;          % installed length
end

%% 7. DESIGN REPORT
b = @(P) P/1e5;  mm = @(x) x*1e3;  mm2 = @(A) A*1e6;
law_txt = {'thesis rule Cd = 1 - 0.7*Pd/Pu', sprintf('constant Cd = %.2f', Cd_constant), 'Perry rule (sharp-edged orifice)'};
fprintf('================ PILOT-OPERATED REGULATOR DESIGN ================\n');
fprintf('Flow coefficient: %s\n', law_txt{flow_coeff_law});
fprintf('Inlet %.1f bar(g) (min %.1f, max %.1f)  ->  outlet %.2f bar(g),  %.0f Nm3/h = %.4f kg/s\n', ...
        b(P1_nom), b(P1_min), b(P1_max), b(P2_set), Q, m);
fprintf('\nPORTS\n');
fprintf('  Inlet port diameter          %8.1f mm   (v <= %g m/s)\n', mm(d_in), v_port);
fprintf('  Outlet port diameter         %8.1f mm\n', mm(d_out));
fprintf('\nMAIN VALVE (sized at P1 min, full flow)\n');
fprintf('  Required flow area           %8.1f mm2\n', mm2(A_main));
fprintf('  Seat diameter                %8.2f mm\n', mm(d_main));
fprintf('  Stroke at full flow, P1 min  %8.3f mm   (P1 nominal: %.3f mm, stop: %.3f mm)\n', mm(x_main), mm(x_main_nom), mm(x_main_max));
fprintf('  Main piston diameter         %8.1f mm   (area %.0f mm2)\n', mm(D_main), mm2(A_mp));
fprintf('  Loading pressure, full open  %8.2f bar(g)  (P_L - P2 = %.2f bar)\n', b(PLf - Pamb), b(dP_full));
fprintf('  Main spring preload          %8.1f N\n', F_m0);
fprintf('  Main spring rate             %8.2f N/mm\n', k_main/1e3);
fprintf('\nBLEED ORIFICE AND PILOT VALVE\n');
fprintf('  Bleed orifice diameter       %8.2f mm\n', mm(d_bleed));
fprintf('  Pilot / bleed flow, full     %8.3f g/s  (%.2f %% of design flow)\n', m_b*1e3, 100*m_b/m);
fprintf('  Pilot seat diameter          %8.2f mm\n', mm(d_pseat));
fprintf('  Pilot flow area              %8.3f mm2\n', mm2(A_pilot));
fprintf('  Pilot stroke at full flow    %8.4f mm\n', mm(x_pilot));
fprintf('  Pilot piston diameter        %8.1f mm   (area %.0f mm2)\n', mm(D_ppist), mm2(A_pp));
fprintf('  Pilot spring force at set    %8.1f N\n', F_p0);
fprintf('  Pilot spring rate            %8.2f N/mm\n', k_pilot/1e3);
fprintf('\nPERFORMANCE (design values)\n');
fprintf('  Droop, no flow -> full flow  %8.3f bar\n', b(droop));
fprintf('  Supply pressure effect       %8.4f bar outlet per bar inlet  (%.3f bar over %g-%g bar(g))\n', ...
        SPE, SPE*b(P1_max - P1_min), b(P1_min), b(P1_max));
fprintf('  Min. inlet-outlet difference %8.2f bar for full opening\n', b(dP_min_needed));
fprintf('\nSPRINGS          wire d   coil D   index C  active  total   free L  installed L  solid L  max stress\n');
for j = 1:2
    fprintf('  %-13s %6.2f mm %6.1f mm %6.1f  %6d %6d %7.1f mm %8.1f mm %7.1f mm %6.0f MPa\n', ...
        sp(j).name, mm(sp(j).d), mm(sp(j).D), sp(j).C, n_active, sp(j).n_total, ...
        mm(sp(j).L_free), mm(sp(j).L_inst), mm(sp(j).L_solid), sp(j).tau/1e6);
end
fprintf('\nCHECKS\n');
yesno = {'NOT OK', 'OK'};
fprintf('  Inlet high enough to load the main piston at P1 min : %s\n', yesno{ok_loading+1});
fprintf('  Main stroke below mechanical stop (d/4)            : %s\n', yesno{ok_stroke+1});
fprintf('  Pilot stroke below pilot seat d/4                  : %s\n', yesno{ok_seat_p+1});
fprintf('  Pilot spring fits inside pilot piston (D < piston) : %s\n', yesno{(sp(2).D < D_ppist)+1});
fprintf('  Spring index 4 <= C <= 12 (main, pilot)            : %s, %s\n', ...
        yesno{(sp(1).C >= 4 && sp(1).C <= 12)+1}, yesno{(sp(2).C >= 4 && sp(2).C <= 12)+1});
fprintf('  Spring buckling, free L / D < 4 (main, pilot)      : %s, %s\n', ...
        yesno{(sp(1).L_free/sp(1).D < 4)+1}, yesno{(sp(2).L_free/sp(2).D < 4)+1});

%% 8. DESIGN CHECK SIMULATION (optional, switch: run_check_sim)
if run_check_sim == 1
% ---- simulation
% States: P2 outlet, PL loading chamber, xm/vm main valve, xp/vp pilot.
% Gas volumes: dP/dt = g*R*T/V * (m_in - m_out)  (constant temperature T)
c_main  = 2*zeta*sqrt(k_main*mass_main);    % damping from damping ratio
c_pilot = 2*zeta*sqrt(k_pilot*mass_pilot);

w_max = max(sqrt(k_main/mass_main), sqrt(k_pilot/mass_pilot));      % highest natural frequency [rad/s]
dt = min(1e-5, 0.1/w_max);                                           % time step small enough for the stiffest spring
t_end = 12;  N = round(t_end/dt) + 1;  t = (0:N-1)'*dt;
% scenario: inlet pressure and flow demand steps
P1t   = P1n*ones(N,1);  P1t(t >= 4) = P1l;  P1t(t >= 6) = P1h;
mdem  = zeros(N,1);  mdem(t >= 0.5) = 0.5*m;  mdem(t >= 2) = m;
mdem(t >= 8) = 0.1*m;  mdem(t >= 10) = 0;

[P2, PL, xm, xp, m_m, m_b_t] = deal(zeros(N,1));
P2_ = P2s;  PL_ = P2s;  xm_ = 0;  vm_ = 0;  xp_ = 0;  vp_ = 0;   % start at lock-up
for n = 1:N
    Pin = P1t(n);
    % flows: main valve, pilot valve, bleed orifice (can reverse)
    mm_ = mdot(Aseat(xm_, d_main), Pin, P2_);
    if Pin > PL_,  mp_ = mdot(Aseat(xp_, d_pseat), Pin, PL_);  else, mp_ = 0;  end
    if PL_ >= P2_, mb_ = mdot(A_b, PL_, P2_);  else, mb_ = -mdot(A_b, P2_, PL_);  end
    % outlet and loading chamber pressures
    dP2 = g*R*T/V_out * (mm_ + mb_ - mdem(n));
    VL  = V_L0 + A_mp*xm_;
    dPL = (g*R*T*(mp_ - mb_) - g*PL_*A_mp*vm_) / VL;
    % forces on the moving parts (positive = opening)
    Fm = (PL_ - P2_)*A_mp - F_m0 - k_main*xm_ - c_main*vm_;
    Fp = F_p0 - k_pilot*xp_ - (P2_ - Pamb)*A_pp - (Pin - PL_)*A_ps - c_pilot*vp_;
    % save
    P2(n) = P2_;  PL(n) = PL_;  xm(n) = xm_;  xp(n) = xp_;  m_m(n) = mm_;  m_b_t(n) = mb_;
    % step forward in time (Euler)
    P2_ = max(P2_ + dP2*dt, 0.05*Pamb);     % (a pressure can never go below zero)
    PL_ = max(PL_ + dPL*dt, 0.05*Pamb);
    vm_ = vm_ + Fm/mass_main*dt;    xm_ = xm_ + vm_*dt;
    vp_ = vp_ + Fp/mass_pilot*dt;   xp_ = xp_ + vp_*dt;
    if xm_ < 0,          xm_ = 0;          vm_ = max(vm_, 0);  end   % main valve on seat
    if xm_ > x_main_max, xm_ = x_main_max; vm_ = min(vm_, 0);  end   % main valve on stop
    if xp_ < 0,          xp_ = 0;          vp_ = max(vp_, 0);  end   % pilot on seat
end

% ---- plots
figure('Name', 'Pilot regulator simulation', 'Position', [100 100 800 900]);
subplot(4,1,1);
plot(t, (P1t-Pamb)/1e5, 'k', t, (PL-Pamb)/1e5, 'r', t, (P2-Pamb)/1e5, 'b'); grid on;
ylabel('bar(g)'); legend('inlet P1', 'loading P_L', 'outlet P2', 'Location', 'northeast');
title('Response to flow and inlet pressure steps'); xlim([0 t_end]);
subplot(4,1,2);
plot(t, (P2-Pamb)/1e5, 'b', t([1 end]), [1 1]*P2_set/1e5, 'k--', t([1 end]), [1 1]*(P2_set-droop)/1e5, 'k:');
grid on; ylim(P2_set/1e5 + [-0.6 1.2]); xlim([0 t_end]); ylabel('P2 bar(g)');
legend('outlet P2', 'set (no flow)', 'set - droop', 'Location', 'northeast');
subplot(4,1,3);
plot(t, xm*1e3, 'b', t, xp*1e3*10, 'r'); grid on; xlim([0 t_end]); ylabel('stroke (mm)');
legend('main valve', 'pilot x 10', 'Location', 'northeast');
subplot(4,1,4);
plot(t, mdem*1e3, 'k', t, m_m*1e3, 'b', t, m_b_t*1e3*100, 'r'); grid on; xlim([0 t_end]);
ylabel('flow (g/s)'); xlabel('Time (s)');
legend('demand', 'main valve', 'bleed x 100', 'Location', 'northeast');

% ---- simulated performance vs design
k = @(tt) round(tt/dt);                    % index just before time tt
fprintf('\nSIMULATION (steady values just before each step)\n');
fprintf('  Full flow, P1 nominal : P2 = %.3f bar(g), main stroke %.3f mm, pilot stroke %.4f mm\n', ...
        (P2(k(4))-Pamb)/1e5, xm(k(4))*1e3, xp(k(4))*1e3);
fprintf('  Full flow, P1 min     : P2 = %.3f bar(g), main stroke %.3f mm, pilot stroke %.4f mm\n', ...
        (P2(k(6))-Pamb)/1e5, xm(k(6))*1e3, xp(k(6))*1e3);
fprintf('  Full flow, P1 max     : P2 = %.3f bar(g), main stroke %.3f mm\n', (P2(k(8))-Pamb)/1e5, xm(k(8))*1e3);
fprintf('  10 %% flow, P1 max     : P2 = %.3f bar(g)\n', (P2(k(10))-Pamb)/1e5);
fprintf('  Peak outlet pressure after the flow drop at 8 s: %.3f bar(g)\n', (max(P2(k(8):end))-Pamb)/1e5);
fprintf('  Design: P2 = %.3f bar(g) at full flow, %.3f bar(g) at no flow\n', (P2f-Pamb)/1e5, P2_set/1e5);
% oscillation check: outlet pressure ripple in the last 0.5 s before each step
t_chk = [2 4 6 8 10 12];  ripple = zeros(size(t_chk));
for q = 1:numel(t_chk)
    w = t >= t_chk(q) - 0.5 & t < t_chk(q);
    ripple(q) = (max(P2(w)) - min(P2(w))) / 1e5;
end
fprintf('  Outlet ripple before each step (bar): %s\n', sprintf('%.4f  ', ripple));
if max(ripple) < 0.01
    fprintf('  -> stable: no sustained oscillation\n');
else
    fprintf('  -> OSCILLATING: increase loading volume V_L0, or reduce pilot seat diameter\n');
end
end
