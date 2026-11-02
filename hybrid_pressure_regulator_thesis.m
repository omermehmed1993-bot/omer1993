%% HYBRID PRESSURE REGULATOR - simple simulation of the thesis results
%
% Reproduces the "simplified nonlinear model" results of:
%   M. G. Gurfidan, "Design and Modelling of a Hybrid Pressure Regulator",
%   MSc thesis, METU, 2022  (Chapter 4, Figures 4.3 - 4.11)
%
% Scenario (thesis section 4.1):
%   - Helium tank empties in 30 s: inlet 300 -> 60 bar, 330 -> 230 K
%   - Constant outlet flow demand: 10, 50 or 90 g/s
%   - Mechanical regulator (spring only) and hybrid regulator
%     (spring + voice-coil actuator with a PI controller, set point 30 bar)
%
% Model (thesis eq. 2.48 - 2.51), 4 states:
%   P   outlet pressure          dP/dt = g*R/V*(Tin*m_in - T*m_out)
%   T   outlet temperature       dT/dt = R*T^2/(V*P)*((g*Tin/T-1)*m_in - (g-1)*m_out)
%   x   poppet stroke            dx/dt = v
%   v   poppet velocity          m*dv/dt = F_spring - pressure force - k*x - c*v + F_coil
%   Flow through the poppet: m_in = Cd*A(x)*f(g)*Pin/sqrt(R*Tin)   (eq. 2.5, choked)
%   Poppet gap area:         A(x) = pi*x*sin(th)*(d1 - x*sin(th)*cos(th))   (eq. 2.27)
%
% Solved with a simple fixed-step (Euler) loop - no toolboxes needed.
% Runs in MATLAB or GNU Octave.

clear; clc; close all;

%% 1. DATA (thesis Table 3.1)
p.R      = 2077;          % gas constant of helium        [J/(kg K)]
p.g      = 1.667;         % ratio of specific heats       [-]
p.d1     = 11.8e-3;       % poppet seat diameter          [m]
p.th     = 45;            % poppet seat angle             [deg]
p.V      = 50e-3;         % outlet volume                 [m^3]  (50 L)
p.c      = 515;           % damping coefficient           [N s/m]
p.k      = 212e3 + 54e3;  % spring stiffness k1 + k2      [N/m]  (eq. 2.47)
p.Pamb   = 101325;        % ambient pressure              [Pa]
p.x0     = 0.17e-3;       % initial stroke = design stroke [m]

% moving mass (eq. 2.36 - 2.38): poppet + piston + springs/3 + lever/coil
m_act    = (0.010*(0.048/2)^2 + 0.085*0.048^2) / 0.006^2;   % lever + coil [kg]
p.m      = 0.020 + 0.080 + (0.154 + 0.007)/3 + m_act;       % total        [kg]

% voice-coil actuator and controller (Table 3.1, eq. 3.15 - 3.16)
p.r_lever = 48/6;         % lever ratio l2/l1             [-]
p.Fc      = 34;           % voice-coil force constant     [N/A]
p.i_max   = 0.8;          % voice-coil current limit      [A]
p.Kp      = 3.276e-6;     % PI proportional gain          [A/Pa]
p.Ki      = 1.337e-4;     % PI integral gain              [A/(Pa s)]
p.Ts      = 1e-3;         % controller sample time        [s]
p.Pset    = 30e5;         % set pressure                  [Pa]

%% 2. CALIBRATION (2 values)
% The thesis curves cannot be reproduced with the Table 3.1 areas
% (net sensing area 1250 - 102 = 1148 mm^2). The thesis's own linear model
% (eq. 3.1) gives  A(4,1) = -1.025e-4 = -A_s / m  ->  A_s = 1.025e-4 * m.
% With this area and the lock-up pressure read from Fig. 4.3 / 4.10
% (30.73 bar at zero stroke) the code matches Figures 4.3 - 4.9.
p.A_s    = 1.025e-4 * p.m;                % effective sensing area   [m^2]  (~598 mm^2)
P_lock   = 30.73e5;                       % outlet P with poppet closed [Pa]
p.F_pre  = (P_lock - p.Pamb) * p.A_s;     % net spring preload       [N]

%% 3. SIMULATION SETTINGS
p.dt     = 1e-4;          % time step [s]
p.t_end  = 30;            % duration  [s]
flows    = [10 50 90]/1000;   % outlet mass flow demand [kg/s]

%% 4. RUN ALL CASES  (simple fixed-step loop, no toolboxes needed)
N   = round(p.t_end/p.dt) + 1;
t   = (0:N-1)' * p.dt;
Pin = (300 - 240*t/30) * 1e5;        % inlet pressure ramp    [Pa] (Fig 4.1)
Tin =  330 - 100*t/30;               % inlet temperature ramp [K]  (Fig 4.2)

f     = sqrt(p.g) * (2/(p.g+1))^((p.g+1)/(2*(p.g-1)));   % eq. 2.6
s     = sind(p.th);   sc = sind(p.th)*cosd(p.th);
nstep = round(p.Ts/p.dt);                                 % controller update every Ts

% results: column j = flow case, page h = 1 mechanical / 2 hybrid
[Pout, Tout, xp, ivc] = deal(zeros(N, numel(flows), 2));

for h = 1:2                          % 1 = mechanical PR, 2 = hybrid PR
  for j = 1:numel(flows)
    m_out = flows(j);
    P = 30e5;  T = 330;  x = p.x0;  v = 0;  i = 0;  e_int = 0;   % initial state

    for n = 1:N
        % PI controller of the voice coil (hybrid only), updated every Ts
        if h == 2 && mod(n-1, nstep) == 0
            e     = p.Pset - P;
            e_int = e_int + e*p.Ts;
            i     = min(max(p.Kp*e + p.Ki*e_int, -p.i_max), p.i_max);
        end

        % flow through the poppet gap (eq. 2.5, 2.9, 2.27; choked flow)
        A    = pi * x * s * (p.d1 - x*sc);
        Cd   = 1 - 0.7*P/Pin(n);
        m_in = Cd * A * f * Pin(n) / sqrt(p.R*Tin(n));

        % outlet volume pressure and temperature (eq. 2.48, 2.49)
        dP = p.g*p.R/p.V * (Tin(n)*m_in - T*m_out);
        dT = p.R*T^2/(p.V*P) * ((p.g*Tin(n)/T - 1)*m_in - (p.g - 1)*m_out);

        % poppet-piston motion (eq. 2.51)
        F  = p.F_pre - (P - p.Pamb)*p.A_s - p.k*x - p.c*v + p.r_lever*p.Fc*i;
        a  = F / p.m;

        % save results, then step forward in time (Euler)
        Pout(n,j,h) = P;  Tout(n,j,h) = T;  xp(n,j,h) = x;  ivc(n,j,h) = i;
        P = P + dP*p.dt;
        T = T + dT*p.dt;
        v = v + a*p.dt;
        x = x + v*p.dt;
        if x < 0                     % poppet sits on its seat
            x = 0;  v = max(v, 0);
        end
    end
    fprintf('done: case %d of 6\n', (h-1)*numel(flows) + j);
  end
end

%% 5. VALUES READ FROM THE THESIS FIGURES (for comparison markers)
ref.t    = [1 5 8 12 15 22.5 25 27.5 29.7];
ref.P10  = [30.668 30.651 30.651 30.634 30.616 30.531 30.480 30.394 30.258]; % Fig 4.3
ref.P50  = [30.377 30.326 30.292 30.207 30.138 29.814 29.592 29.250 28.686]; % Fig 4.4
ref.P90  = [30.104 30.002 29.933 29.814 29.677 29.113 28.738 28.157 27.234]; % Fig 4.5
ref.x90  = [0.143 0.165 0.180 0.208 0.236 0.360 0.444 0.568 0.764];          % Fig 4.6
ref.ti   = [5 15 18 22.5 25 27.5 29];
ref.i90  = [-0.007 0.066 0.105 0.204 0.290 0.447 0.605];                     % Fig 4.9

%% 6. PLOTS
col   = {'b', 'r', 'k'};
names = {'10 g/s', '50 g/s', '90 g/s'};

% Inlet conditions (Fig 4.1, 4.2)
figure('Name', 'Inlet profile');
subplot(2,1,1); plot(t, Pin/1e5, 'b'); grid on;
ylabel('P_{inlet} (bar)'); title('Inlet pressure (Fig 4.1)');
subplot(2,1,2); plot(t, Tin, 'b'); grid on;
ylabel('T_{inlet} (K)'); xlabel('Time (s)'); title('Inlet temperature (Fig 4.2)');

% Mechanical regulator outlet pressure (Fig 4.3 - 4.5, 4.10)
figure('Name', 'Mechanical PR'); hold on; grid on;
for j = 1:3
    plot(t, Pout(:,j,1)/1e5, col{j});
end
plot(ref.t, ref.P10, 'bo', ref.t, ref.P50, 'ro', ref.t, ref.P90, 'ko');
ylim([26.5 32]); xlabel('Time (s)'); ylabel('P_{outlet} (bar)');
title('Mechanical PR regulation (Fig 4.3 - 4.5, 4.10)');
legend('model 10 g/s', 'model 50 g/s', 'model 90 g/s', ...
       'thesis 10 g/s', 'thesis 50 g/s', 'thesis 90 g/s', 'Location', 'southwest');

% Poppet stroke at 90 g/s (Fig 4.6)
figure('Name', 'Poppet stroke');
plot(t, xp(:,3,1)*1e3, 'k', ref.t, ref.x90, 'ko'); grid on; ylim([0 1]);
xlabel('Time (s)'); ylabel('x_p (mm)');
title('Mechanical PR poppet position, 90 g/s (Fig 4.6)'); legend('model', 'thesis', 'Location', 'northwest');

% Hybrid regulator outlet pressure and coil current (Fig 4.7 - 4.9, 4.11)
figure('Name', 'Hybrid PR');
subplot(2,1,1); hold on; grid on;
for j = 1:3
    hp(j) = plot(t, Pout(:,j,2)/1e5, col{j}, 'LineWidth', 2);
end
ylim([27 32]); ylabel('P_{outlet} (bar)'); legend(hp, names, 'Location', 'southeast');
title('Hybrid PR regulation (Fig 4.7 - 4.9, 4.11)');
subplot(2,1,2); hold on; grid on;
for j = 1:3
    hi(j) = plot(t, ivc(:,j,2), col{j});
end
hi(4) = plot(ref.ti, ref.i90, 'ko');
ylim([-0.8 0.8]); xlabel('Time (s)'); ylabel('i_{vc} (A)');
legend(hi, [names, {'thesis 90 g/s'}], 'Location', 'northwest');

%% 7. TABLE: model vs thesis at the comparison times
fprintf('\n  t(s) | Pout 10 g/s  model / thesis | Pout 90 g/s  model / thesis | x 90 g/s  model / thesis\n');
for n = 1:numel(ref.t)
    k = round(ref.t(n)/p.dt) + 1;
    fprintf('%6.1f |     %7.3f / %7.3f bar     |     %7.3f / %7.3f bar     |    %6.3f / %6.3f mm\n', ...
        ref.t(n), Pout(k,1,1)/1e5, ref.P10(n), Pout(k,3,1)/1e5, ref.P90(n), xp(k,3,1)*1e3, ref.x90(n));
end
k1 = round(1/p.dt) + 1;    % ignore the first second (start-up transient)
fprintf('\nHybrid PR outlet pressure after t = 1 s: %.3f to %.3f bar (set point 30 bar)\n', ...
    min(min(Pout(k1:end,:,2)))/1e5, max(max(Pout(k1:end,:,2)))/1e5);
