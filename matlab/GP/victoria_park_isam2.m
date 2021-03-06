%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% @author Xinyan
% @date Dec 20, 2015
% Modified from RangeISAMExample_plaza.m in the GTSAM 3.2 matlab toolbox
% GTSAM: https://collab.cc.gatech.edu/borg/gtsam/
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Victoria Park dataset
% Augmented iSAM2 with Gaussian process prior and velocity measurements
% with double trajectory variables because of velocities

clear;
import gtsam.*
isam = ISAM2;
datafile = '../Data/new_victoria_park.txt';
[measurements, initial] = load2D(datafile);

%% Parameters
nrc = 0;                    % number of range measurements since previous isam2 update
nrpu = 10;                % number of range measurements per isam2 update
% nrpu = incK;               
% to_visualize = true;
to_visualize = false;
visualI = 500;
nSteps = 6968;
periodic_script = false;

%% Noise models
delta_t = 1;
dt = 1;
noiseModels.velProj = noiseModel.Diagonal.Sigmas([0.01; 0.002; 0.002]);   % velocity projected
Qc = diag([1, 1, 2])*0.01;                                                % Qc in dynamics model
Qi = [1/3 * delta_t ^3 * Qc, 1/2 * delta_t^2 * Qc; 1/2 * delta_t^2 * Qc, delta_t * Qc];
noiseModels.gp = noiseModel.Gaussian.Covariance(Qi);
noiseModels.prior = noiseModel.Diagonal.Sigmas([1 1 pi]');


% New variables and priors
pose0 = Pose2();
pose0lv = LieVector([0;0;0]);
vel0 = LieVector([1e-4;1e-4;1e-4]);
newFactors = NonlinearFactorGraph;
newFactors.add(PriorFactorLieVector(symbol('P', 0), pose0lv, noiseModel.Diagonal.Sigmas([1 1 pi]')));
newFactors.add(PriorFactorLieVector(symbol('V', 0), vel0, noiseModel.Diagonal.Sigmas([0.1 0.1 pi/10]')));

newVariables = Values;
newVariables.insert(symbol('P', 0), pose0lv);
newVariables.insert(symbol('V', 0), vel0);

odo = Values;
odo.insert(symbol('P', 0), Pose2());

lastPose = pose0;
lastPoselv = pose0lv;
odoPose = pose0;

%% Loop over
step_t = zeros(8000, 2);
estStateInds = zeros(8000,1);
nEstStateInds = 1;
ipv = 0;
nextMeasurement = 0;        % index in C++ starts from 0
step = 1;                   % the index of trajectory state we are looking at / time step
landmarkKeyOffset = symbol('l', 0);
while (nextMeasurement < measurements.size())
    tic;
    while (nextMeasurement < measurements.size())
        % Get the new measurement and keys
        % In victoria park file, only consist of measurements that involve
        % two keys
        measurement = measurements.at(nextMeasurement);
        kV = measurement.keys();
        k1 = kV.at(0);  k2 = kV.at(1);
        
        % Between Factor?
        if (isa(measurement,'gtsam.BetweenFactorPose2'))
            % In load2D, the second key in the LANDMARK measurement is
            % automatically prefixed with 'l'
            
            % k2 should be bigger than k1
            if (k2 <= k1), disp('Wrong keys!'); return; end
            % Stop processing measurements that are for future steps
            if (k2 > step), break; end
            % Code error
            if (k2 ~= step), disp('Code error!'); return; end
            % Too big leap
            if (k2 - k1 >= 2), disp('Too big leap!'); return; end
            % Now (k2 == step) and (k2 = k1+1)
            measured = measurement.measured();
            
            predOdo = odoPose.compose(measured);
            odoPose = predOdo;
            odo.insert(symbol('P',step),predOdo);
            
            predPose =  lastPose.compose(measured);
            pmv = lastPoselv.vector();
            predPoselv = LieVector([predPose.x(); predPose.y(); pmv(3)+measured.theta()]);
            lastPoselv = predPoselv;
            
            longV = measured.x() / dt;
            latV = measured.y() / dt;
            thetaV = measured.theta() / dt;
            velProj = LieVector([longV, latV, thetaV]');
            deltaX = predPose.x() - lastPose.x();
            deltaY = predPose.y() - lastPose.y();
            deltaTheta = predPose.theta() - lastPose.theta();
            predVel = LieVector( [deltaX / dt, deltaY / dt, deltaTheta / dt]');
            
            lastPose = predPose;
            
            newVariables.insert(symbol('P', step), predPoselv);
            newVariables.insert(symbol('V', step), predVel);
            nEstStateInds = nEstStateInds + 1;
            estStateInds(nEstStateInds) = step;
            newFactors.add(VFactorLieVector(symbol('P', step), symbol('V', step), velProj, noiseModels.velProj));
            newFactors.add(GaussianProcessPriorPose2LieVector(symbol('P', step-1), symbol('V', step-1), ...
                symbol('P', step), symbol('V', step), dt, noiseModels.gp));
            
            
            % Landmark Bearing Range Factor
        elseif (isa(measurement,'gtsam.BearingRangeFactor2D'))
            poseKey = k1; landmarkKey = k2 - landmarkKeyOffset;
            if (poseKey > step), disp('Code error'); return; end
            % The related pose has been added to isam
            % No need to have been added to isam
            [measuredBearing, measuredRange] = measurement.measured();
            noise = measurement.get_noiseModel();
            measurement = BearingRangeFactorLV2D(symbol('P', poseKey), symbol('L', landmarkKey),...
                measuredBearing, measuredRange, noise);
            newFactors.push_back(measurement);
            if (~isam.getLinearizationPoint().exists(symbol('L', landmarkKey)) ...
                    && ~newVariables.exists(symbol('L', landmarkKey)))
                pose = lastPose;
                newVariables.insert(symbol('L', landmarkKey), ...
                    pose.transform_from(measuredBearing.rotate( ...
                    Point2(measuredRange, 0.0))));
            end
            nrc = nrc + 1;
        else
            disp('Unknown measuremnent!');
            return;
        end
        nextMeasurement = nextMeasurement + 1;
    end
    
    if (nrc >= nrpu) || (step == nSteps)
        isam.update(newFactors, newVariables);
        result = isam.calculateEstimate();
        lastPoselv = result.at(symbol('P',step));
        lastPose = lastPoselv.vector();   % update last pose
        lastPose = Pose2(lastPose(1), lastPose(2), lastPose(3));
        newVariables = Values;
        newFactors = NonlinearFactorGraph;
        nrc = 0;
        step_t(step, 1) = step_t(step, 1) + toc;    % clock stop    

        % Visualize
        if step - ipv >= visualI && to_visualize
            ipv = step;
            figure(1);clf;hold on      
            loop_plot;
        end
        tic;  
    end

    step_t(step, 1) = step_t(step, 1) + toc;    
    if (step == 1)
        step_t(step, 2) = step_t(step, 1);
    else
        step_t(step, 2) = step_t(step, 1) + step_t(step-1, 2);
    end
    step = step+1;
end
step_t = step_t(1:step-1, :);

%% Plot final result
figure;
hold on;
sz = nEstStateInds;
result = isam.calculateEstimate();
P = zeros(sz, 3);
Pdot = zeros(sz, 3);
for i=1:sz
    P(i,:) = result.at(symbol('P', estStateInds(i))).vector()';
    Pdot(i,:) = result.at(symbol('V', estStateInds(i))).vector()';
end

% Save to XYT
XYT = P;
XYT_dot = Pdot;

% Estimated states
hestimated_trajectory = plot(P(:,1), P(:,2), 'r-', 'LineWidth', 2);
% odometry
XYT_dead = utilities.extractPose2(odo);
hdead = plot(XYT_dead(:,1),XYT_dead(:,2),'m-.');

% Estimated landmarks
XY = utilities.extractPoint2(result);
hestimated_landmarks = plot(XY(:,1), XY(:,2), 'b+', 'LineWidth', 2);

hmap = legend([hdead, hestimated_trajectory, hestimated_landmarks], ...
    'dead reckoning Path', 'est. Path', 'est. Landmarks');
set(hmap,'FontSize',14);
set(gca,'FontSize',13)

               
                                                                                                                      