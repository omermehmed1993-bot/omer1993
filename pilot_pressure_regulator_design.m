%% PILOT-OPERATED PRESSURE REGULATOR - design calculation + simulation
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
% The script:
%   1. takes the requirements (gas, P, T, flow, accuracy)
%   2. sizes every part: ports, main seat + stroke, main piston, main spring,
%      bleed orifice, pilot seat + stroke, pilot piston, pilot spring,
%      spring wire / coil geometry, and works out droop, supply-pressure effect
%   3. simulates the regulator in time to check the design
%
% Flow equations as in the previous work (Gurfidan, METU 2022, eq. 2.5 - 2.9,
% 2.27): m = Cd*A*f(g)*N*Pu/sqrt(R*T),  Cd = 1 - 0.7*Pd/Pu,
% conical seat area A = pi*x*sin(th)*(d - x*sin(th)*cos(th)).
% Runs in MATLAB or GNU Octave, no toolboxes needed.

clear; clc; close all;

%% 1. REQUIREMENTS  (edit these)
R      = 287;        % gas constant, air          [J/(kg K)]
g      = 1.4;        % ratio of specific heats    [-]
T      = 20 + 273.15;% gas temperature            [K]
Pamb   = 101325;     % ambient pressure           [Pa]

P1_nom = 10e5;       % nominal inlet pressure     [Pa gauge]
P1_min =  8e5;       % minimum inlet pressure     [Pa gauge]  (valve sized here)
P1_max = 12e5;       % maximum inlet pressure     [Pa gauge]  (lock-up checked here)
P2_set =  6e5;       % outlet set pressure        [Pa gauge]
P2_adj = [4e5 8e5];  % pilot spring adjustment range [Pa gauge]
Q      = 500;        % design flow                [Nm3/h]  (0 degC, 1.01325 bar)
droop  = 0.10e5;     % allowed outlet drop from no flow to full flow [Pa]

%% 2. DESIGN CHOICES  (typical values - edit if needed)
v_port   = 30;       % max gas velocity in the ports              [m/s]
th_deg   = 45;       % seat angle, main and pilot                 [deg]
x_d_main = 0.15;     % main stroke / main seat diameter at full flow [-]
D_ratio  = 2.0;      % main piston diameter / main seat diameter  [-]
dP_crack = 0.2e5;    % P_L - P2 at which the main valve starts to open [Pa]
dP_full  = 1.0e5;    % P_L - P2 at full main valve opening        [Pa]
d_bleed  = 1.0e-3;   % bleed orifice diameter                     [m]
d_pseat  = 2.0e-3;   % pilot seat diameter                        [m]
D_ppist  = 25e-3;    % pilot piston diameter                      [m]
% springs (helical compression, steel)
G_spring = 79.3e9;   % shear modulus                              [Pa]
tau_all  = 600e6;    % allowed shear stress                       [Pa]
n_active = 6;        % active coils                               [-]
% dynamics (for the simulation only)
mass_main  = 0.25;   % main poppet + piston moving mass           [kg]
mass_pilot = 0.03;   % pilot plug + piston moving mass            [kg]
zeta     = 0.7;      % damping ratio of both moving parts (seals) [-]
V_out    = 5e-3;     % downstream volume (pipe / receiver)        [m3]
V_L0     = 100e-6;   % loading chamber volume, main valve closed  [m3]
                     % (acts as a filter: below ~40 cm3 this design's pilot oscillates)

%% 3. GAS FUNCTIONS (thesis eq. 2.5 - 2.9, 2.27)
f    = sqrt(g) * (2/(g+1))^((g+1)/(2*(g-1)));          % eq. 2.6
pcr  = (2/(g+1))^(g/(g-1));                            % critical ratio, eq. 2.8
Nden = (g-1)/2 * (2/(g+1))^((g+1)/(g-1));
Nf   = @(r) (r <= pcr) + (r > pcr) .* sqrt(max(r.^(2/g) - r.^((g+1)/g), 0) / Nden);   % eq. 2.7
mdot = @(A, Pu, Pd) (1 - 0.7*Pd./Pu) .* A * f .* Nf(Pd./Pu) .* Pu / sqrt(R*T);       % eq. 2.5, 2.9
Areq = @(m, Pu, Pd) m * sqrt(R*T) ./ ((1 - 0.7*Pd./Pu) * f .* Nf(Pd./Pu) .* Pu);     % eq. 2.5 solved for A
s    = sind(th_deg);  sc = sind(th_deg)*cosd(th_deg);
Aseat  = @(x, d) pi * max(x,0) .* s .* (d - max(x,0)*sc);                           % eq. 2.27
stroke = @(A, d) (d - sqrt(d.^2 - 4*sc*A/(pi*s))) / (2*sc);                        % eq. 2.27 solved for x

%% 4. DESIGN CALCULATION
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
for j = 1:2
    for d = 0.2e-3:0.05e-3:20e-3                                % try wire sizes
        D  = (G_spring*d^4 / (8*n_active*sp(j).k))^(1/3);         % coil diameter from rate
        C  = D/d;  Kw = (4*C-1)/(4*C-4) + 0.615/C;
        tau = 8*sp(j).F(2)*D*Kw / (pi*d^3);
        if tau <= tau_all, break; end
    end
    sp(j).d = d;  sp(j).D = D;  sp(j).C = C;  sp(j).tau = tau;
    sp(j).n_total  = n_active + 2;                               % closed + ground ends
    sp(j).L_solid  = sp(j).n_total * d;
    sp(j).L_free   = sp(j).L_solid + 1.15*sp(j).F(2)/sp(j).k;    % 15 % clash allowance
    sp(j).L_inst   = sp(j).L_free - sp(j).F(1)/sp(j).k;          % installed length
end

%% 5. DESIGN REPORT
b = @(P) P/1e5;  mm = @(x) x*1e3;  mm2 = @(A) A*1e6;
fprintf('================ PILOT-OPERATED REGULATOR DESIGN ================\n');
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

%% 6. SIMULATION (check the design in time)
% States: P2 outlet, PL loading chamber, xm/vm main valve, xp/vp pilot.
% Gas volumes: dP/dt = g*R*T/V * (m_in - m_out)  (constant temperature T)
c_main  = 2*zeta*sqrt(k_main*mass_main);    % damping from damping ratio
c_pilot = 2*zeta*sqrt(k_pilot*mass_pilot);

dt = 1e-5;  t_end = 12;  N = round(t_end/dt) + 1;  t = (0:N-1)'*dt;
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
    P2_ = P2_ + dP2*dt;
    PL_ = PL_ + dPL*dt;
    vm_ = vm_ + Fm/mass_main*dt;    xm_ = xm_ + vm_*dt;
    vp_ = vp_ + Fp/mass_pilot*dt;   xp_ = xp_ + vp_*dt;
    if xm_ < 0,          xm_ = 0;          vm_ = max(vm_, 0);  end   % main valve on seat
    if xm_ > x_main_max, xm_ = x_main_max; vm_ = min(vm_, 0);  end   % main valve on stop
    if xp_ < 0,          xp_ = 0;          vp_ = max(vp_, 0);  end   % pilot on seat
end

%% 7. PLOTS
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

%% 8. SIMULATED PERFORMANCE vs DESIGN
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
