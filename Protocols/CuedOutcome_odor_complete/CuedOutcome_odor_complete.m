%{
----------------------------------------------------------------------------

This file is part of the Bpod Project
Copyright (C) 2014 Joshua I. Sanders, Cold Spring Harbor Laboratory, NY, USA

----------------------------------------------------------------------------

This program is free software: you can redistribute it and/or modify
it under the terms neral Public License as published by
the Free Software Foundation, version 3.

This program is distributed  WITHOUT ANY WARRANTY and without even the
implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.
%}
function CuedOutcome_odor_complete
    % Cued outcome task
    % Written by Fitz Sturgill 3/2016.

    % Photometry with LED light sources, 2Channels
   
    
    global BpodSystem nidaq

    TotalRewardDisplay('init')
    %% Define parameters
    S = BpodSystem.ProtocolSettings; % Load settings chosen in launch manager into current workspace as a struct called S


    if isempty(fieldnames(S))  % If settings file was an empty struct, populate struct with default settings
        S.GUI.LED1_amp = 1.5;
        S.GUI.LED2_amp = 0;
        S.GUI.mu_iti = 6; % 6; % approximate mean iti duration
        S.GUI.highValueOdorValve = 5; % output pin on the slave arduino switching a particular odor valve
        S.GUI.lowValueOdorValve = 6;
        S.GUI.Delay = 1;
        S.GUI.Epoch = 1;
        S.GUI.highValuePunishFraction = 0.10;
        S.GUI.lowValuePunishFraction = 0.55;
        S.GUI.PunishValveTime = 0.2; %s        
        S.GUI.Reward = 8;
        S.GUI.OdorTime = 1; % 0.5s tone, 1s delay        
        S.GUI.Delay = 1; %  time after odor and before US delivery (or omission)
        S.GUI.PunishOn = 1;
        
        S.NoLick = 0; % forget the nolick
        S.ITI = []; %ITI duration is set to be exponentially distributed later
        S.RewardValveCode = 1;
        S.PunishValveCode = 2;
        S.currentValve = []; % holds odor valve # for current trial
        S.RewardValveTime =  GetValveTimes(S.GUI.Reward, S.RewardValveCode);

        % state durations in behavioral protocol
        S.PreCsRecording  = 3; % After ITI        was 3
        S.PostUsRecording = 4; % After trial before exit    was 5

        S.ToneFreq = 10000; % frequency of neutral tone signaling onset of U.S.
        S.ToneDuration = 0.1; % duration of neutral tone
    end
    
    %% Pause and wait for user to edit parameter GUI 
    BpodParameterGUI('init', S);    
    BpodSystem.Pause = 1;
    HandlePauseCondition; % Checks to see if the protocol is paused. If so, waits until user resumes.
    S = BpodParameterGUI('sync', S); % Sync parameters with BpodParameterGUI plugin
    BpodSystem.ProtocolSettings = S; % copy settings back prior to saving
    SaveBpodProtocolSettings;



    %% Initialize NIDAQ
    S.nidaq.duration = S.PreCsRecording + S.GUI.OdorTime + S.GUI.Delay + S.PostUsRecording;
    S = initPhotometry(S);

    %% Initialize Sound Stimuli
    SF = 192000; 
    % linear ramp of sound for 10ms at onset and offset
    neutralTone = taperedSineWave(SF, S.ToneFreq, S.ToneDuration, 0.01); % 10ms taper
    PsychToolboxSoundServer('init')
    PsychToolboxSoundServer('Load', 1, neutralTone);
    BpodSystem.SoftCodeHandlerFunction = 'SoftCodeHandler_PlaySound';

    %% Initialize olfactometer and point grey camera
    % retrieve machine specific olfactometer settings
    addpath(genpath(fullfile(BpodSystem.BpodPath, 'Settings Files'))); % Settings path is assumed to be shielded by gitignore file
    olfSettings = machineSpecific_Olfactometer;
    rmpath(genpath(fullfile(BpodSystem.BpodPath, 'Settings Files'))); % remove it just in case there would somehow be a name conflict

    % retrieve machine specific point grey camera settings
    addpath(genpath(fullfile(BpodSystem.BpodPath, 'Settings Files'))); % Settings path is assumed to be shielded by gitignore file
    pgSettings = machineSpecific_pointGrey;
    rmpath(genpath(fullfile(BpodSystem.BpodPath, 'Settings Files'))); % remove it just in case there would somehow be a name conflict    

    % initialize olfactometer slave arduino
    valveSlave = initValveSlave(olfSettings.portName);
    if isempty(valveSlave)
        BpodSystem.BeingUsed = 0;
        error('*** Failure to initialize valve slave ***');
    end    

    % determine nidaq/point grey and olfactometer triggering arguments
    npgWireArg = 0;
    npgBNCArg = 1; % BNC 1 source to trigger Nidaq is hard coded
    switch pgSettings.triggerType
        case 'WireState'
            npgWireArg = bitset(npgWireArg, pgSettings.triggerNumber); % its a wire trigger
        case 'BNCState'
            npgBNCArg = bitset(npgBNCArg, pgSettings.triggerNumber); % its a BNC trigger
    end
    olfWireArg = 0;
    olfBNCArg = 0;
    switch olfSettings.triggerType
        case 'WireState'
            olfWireArg = bitset(olfWireArg, olfSettings.triggerNumber);
        case 'BNCState'
            olfBNCArg = bitset(olfBNCArg, olfSettings.triggerNumber);
    end



    %% Init Plots
    scrsz = get(groot,'ScreenSize'); 

    BpodSystem.ProtocolFigures.NIDAQFig       = figure(...
        'Position', [25 scrsz(4)*2/3-100 scrsz(3)/2-50  scrsz(4)/3],'Name','NIDAQ plot','numbertitle','off');
    BpodSystem.ProtocolFigures.NIDAQPanel1     = subplot(2,1,1);
    BpodSystem.ProtocolFigures.NIDAQPanel2     = subplot(2,1,2);

    %% initialize trial types and outcomes
    TrialTypes = [];
    UsOutcomes = [];  % remember! these can't be left as zeros because they are used as indexes by processAnalysis_Photometry
    Us = {};
    Cs = []; % zeros for uncued


    %% init outcome plot

    scrsz = get(groot,'ScreenSize');
    % i need to mimic bpod integrated figures (see other protocols) so it
    % is closed properly on bpod protocol stop
    outcomeFig = ensureFigure('Outcome_plot', 1);
    set(outcomeFig, 'Position', [25 scrsz(4)/2-150 scrsz(3)-50  scrsz(4)/6],'numbertitle','off', 'MenuBar', 'none'); %, 'Resize', 'off');    
    outcomeAxes = axes('Parent', outcomeFig);
%     placeHolder = line([1 1], [min(unique(TrialTypes)) max(unique(TrialTypes))], 'Color', [0.8 0.8 0.8], 'LineWidth', 4, 'Parent', outcomeAxes);    
    hold on;
    outcomesHandle = scatter([], []);
    outcomeSpan = 20;
%     set(outcomeAxes, 'XLim', [0 outcomeSpan]);

%% init lick raster plot
    lickPlot = struct(...
        'lickRasterFig', [],...
        'Ax', [],...
        'Types', [],...
        'Outcomes', []...
        );
    lickPlot.lickRasterFig = ensureFigure('Reward_Licks', 1);
    lickPlot.Ax(1) = subplot(2,1,1); title('Reward Cued');
    lickPlot.Ax(2) = subplot(2,1,2); title('Reward Uncued');
    lickPlot.Types{1} = [1 2 3]; % 
    lickPlot.Types{2} = [4 5 6];
    lickPlot.Outcomes{1} =  [1 2 3];
    lickPlot.Outcomes{2} = [1 2 3];

    %% Main trial loop
    for currentTrial = 1:MaxTrials
        S = BpodParameterGUI('sync', S); % Sync parameters with BpodParameterGUI plugin 
        
        %% determine trial type on the fly
        pfh = S.GUI.highValuePunishFraction;
        pfl = S.GUI.lowValuePunishFraction;
        if S.GUI.PunishOn
            typeMatrix = [...
                % high value odor
                1, 0.425 * (1 - pfh - 0.1);... %  reward
                2, 0.425 * pfh;...  % punish
                3, 0.425 * 0.1;... % omit- signal with neutral cue (tone)
                % low value odor
                4, 0.425 * (1 - pfl - 0.1);... %  reward
                5, 0.425 * pfl;... % punish
                6, 0.425 * 0.1;... % omit
                % uncued
                7, 0.05;... % reward
                8, 0.05;... % punish
                9, 0.05;... % neutral
                ];
        else
            typeMatrix = [...
                % high value odor (no punish)
                1, 0.8 * 0.9;... %  reward
                3, 0.8 * 0.1;...  % omit 
                % uncued
                7, 0.1;...  % reward
                9, 0.1;...  % neutral
                ];
        end        
        TrialType = defineRandomizedTrials(typeMatrix, 1);
        %% define outcomes, sound durations, and valve times

        % determine outcomes
        if ismember(TrialType, [1 4 7])
            UsOutcomes(currentTrial) = 1; % reward
            Us{currentTrial} = 'Reward';
            UsAction = {'ValveState', S.RewardValveCode, 'SoftCode', 1};
            UsTime = S.RewardValveTime;
        elseif ismember(TrialType, [2 5 8])
            UsOutcomes(currentTrial) = 2; % punish
            Us{currentTrial} = 'Punish';    
            UsAction = {'ValveState', S.PunishValveCode, 'SoftCode', 1};
            UsTime = S.GUI.PunishValveTime;
        else % implicitly TrialType must be one of [3 6 9] 
            UsOutcomes(currentTrial) = 3; % omit
            Us{currentTrial} = 'Omit';        
            UsAction = {'SoftCode', 1};
            UsTime = (S.RewardValveTime + S.GUI.PunishValveTime)/2; % split the difference, both should be very short            
        end

        % determine cue
        if ismember(TrialTypes, [1 2 3])
            Cs(currentTrial) = S.GUI.highValueOdorValve;
        elseif ismember(TrialTypes, [4 5 6])
            Cs(currentTrial) = S.GUI.lowValueOdorValve;        
        else
            Cs(currentTrial) = 0; % no odor cue
        end    
        
        % update outcome plot to reflect currently executed trial
        set(outcomeAxes, 'XLim', [max(0, currentTrial - outcomeSpan), currentTrial]);
        set(placeHolder, 'XData', [currentTrial currentTrial]);   
        
        % update odor valve number for current trial
        slaveResponse = updateValveSlave(valveSlave, Cs(end)); %Cs == odor valve
        S.currentValve = slaveResponse;
        if isempty(slaveResponse);
            disp(['*** Valve Code not succesfully updated, trial #' num2str(currentTrial) ' skipped ***']);
            continue
        else
            disp(['*** Valve #' num2str(slaveResponse) ' Trial #' num2str(currentTrial) ' ***']);
        end

        S.ITI = inf;
        while S.ITI > 3 * S.GUI.mu_iti   % cap exponential distribution at 3 * expected mean value (1/rate constant (lambda))
            S.ITI = exprnd(S.GUI.mu_iti);
        end

        BpodSystem.Data.Settings = S; % is this necessary???
        sma = NewStateMatrix(); % Assemble state matrix
        sma = AddState(sma, 'Name', 'Start', ...
            'Timer', 0.025,...
            'StateChangeConditions', {'Tup', 'NoLick'},...
            'OutputActions', {}); % Trigger Point Grey Camera and Bonsai
        sma = AddState(sma,'Name', 'NoLick', ...
            'Timer', S.NoLick,...
            'StateChangeConditions', {'Tup', 'ITI','Port1In','RestartNoLick'},... %port 1 is hard coded now, change?
            'OutputActions', {'PWM1', 255}); %Light On
        sma = AddState(sma,'Name', 'RestartNoLick', ...
            'Timer', 0,...
            'StateChangeConditions', {'Tup', 'NoLick',},...
            'OutputActions', {'PWM1', 255}); %Light On
        sma = AddState(sma, 'Name', 'ITI', ...
            'Timer',S.ITI,...
            'StateChangeConditions', {'Tup', 'StartRecording'},...
            'OutputActions',{});
% trigger nidaq and point grey: my 2 bpods have different issues, for one,
% bnc2 doesn't work, for the other, the wire outputs don't work. npgBNCArg
% and npgWireArg provide a merged solution for this conflict that depends
% on a initializion function provided in the settings directory
        sma = AddState(sma, 'Name', 'StartRecording',...
            'Timer',0.025,...
            'StateChangeConditions', {'Tup', 'PreCsRecording'},...
            'OutputActions', {'BNCState', npgBNCArg, 'WireState', npgWireArg});         
        sma = AddState(sma, 'Name','PreCsRecording',...
            'Timer',S.PreCsRecording,...
            'StateChangeConditions',{'Tup','DeliverStimulus'},...
            'OutputActions',{});
        sma = AddState(sma, 'Name', 'Cue', ... 
            'Timer', S.GUI.OdorTime,...
            'StateChangeConditions', {'Tup','Delay'},...
            'OutputActions', {'WireState', olfWireArg, 'BNCState', olfBNCArg});
        sma = AddState(sma, 'Name', 'Delay', ... 
            'Timer', S.GUI.Delay,...
            'StateChangeConditions', {'Tup', Us{currentTrial}},...
            'OutputActions', {});         
        sma = AddState(sma,'Name', 'Us', ...
            'Timer',UsTime,... % time will be 0 for omission
            'StateChangeConditions', {'Tup', 'PostUsRecording'},...
            'OutputActions', UsAction);
        sma = AddState(sma, 'Name','PostUsRecording',...
            'Timer',S.PostUsRecording,...  
            'StateChangeConditions',{'Tup','exit'},...
            'OutputActions',{});

        %%
        BpodSystem.Data.TrialSettings(currentTrial) = S; % Adds the settings used for the current trial to the Data struct (to be saved after the trial ends)
        SendStateMatrix(sma);

        %% prep data acquisition
        updateLEDData(S); % FS MOD        
        nidaq.ai_data = [];
        nidaq.session.prepare(); %Saves 50ms on startup time, perhaps more for repeats.
        nidaq.session.startBackground(); % takes ~0.1 second to start and release control.

        %% Run state matrix
        RawEvents = RunStateMatrix();  % Blocking!

        %% Clean up data acquisition
        pause(0.05); 
        nidaq.session.stop() % Kills ~0.002 seconds after state matrix is done.
        wait(nidaq.session) % Trying to wait until session is done - did we record the full session?

        % demodulate and plot trial data
        try
            updatePhotometryPlot;
        catch
        end
        % ensure outputs reset to zero
        nidaq.session.outputSingleScan(zeros(1,length(nidaq.aoChannels)));

        %% Save data in BpodSystem format.
        BpodSystem.Data.NidaqData{currentTrial, 1} = nidaq.ai_data; %input data
        BpodSystem.Data.NidaqData{currentTrial, 2} = nidaq.ao_data; % output data
        if ~isempty(fieldnames(RawEvents)) % If trial data was returned
            BpodSystem.Data = AddTrialEvents(BpodSystem.Data,RawEvents); % Computes trial events from raw data
            BpodSystem.Data.TrialSettings(currentTrial) = S; % Adds the settings used for the current trial to the Data struct (to be saved after the trial ends)
            BpodSystem.Data.TrialTypes(currentTrial) = TrialTypes(currentTrial); % Adds the trial type of the current trial to data
            BpodSystem.Data.TrialOutcome(currentTrial) = UsOutcomes(currentTrial);
            BpodSystem.Data.OdorValve(currentTrial) =  odorValve;
            BpodSystem.Data.Epoch(currentTrial) = S.GUI.Epoch;
            try
                BpodSystem.Data.Us(currentTrial) = Us{currentTrial}; % fluff, nice to have the strings for 'reward', 'punish', 'omit'
            catch
                BpodSystem.Data.Us = Us{currentTrial}; % I'm in a hurry...
            end

            if ismember(TrialType, [1 4 7])
                TotalRewardDisplay('add', S.GUI.Reward); 
            end
            bpLickRaster(BpodSystem.Data, lickPlot.Types{1}, lickPlot.Outcomes{1}, 'DeliverStimulus', [], lickPlot.Ax(1));
            set(gca, 'XLim', [-3, 6]);
            bpLickRaster(BpodSystem.Data, lickPlot.Types{2}, lickPlot.Outcomes{2}, 'DeliverStimulus', [], lickPlot.Ax(2));            
            set(gca, 'XLim', [-3, 6]);            
            %save data
            SaveBpodSessionData; % Saves the field BpodSystem.Data to the current data file
        else
            disp('WTF');
        end
        HandlePauseCondition; % Checks to see if the protocol is paused. If so, waits until user resumes.
        if BpodSystem.BeingUsed == 0
            fclose(valveSlave);
            delete(valveSlave);
            return
        end 
    end
end

function SoftCodeHandler_PlaySound(SoundID)
    if SoundID == 255
        PsychToolboxSoundServer('StopAll');
    else
        PsychToolboxSoundServer('Play', SoundID);
    end
end   