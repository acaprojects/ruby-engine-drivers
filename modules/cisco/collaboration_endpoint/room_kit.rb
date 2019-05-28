# frozen_string_literal: true

load File.join(__dir__, 'room_os.rb')
load File.join(__dir__, 'ui_extensions.rb')
load File.join(__dir__, 'external_source.rb')

class Cisco::CollaborationEndpoint::RoomKit < Cisco::CollaborationEndpoint::RoomOs
    include ::Cisco::CollaborationEndpoint::Xapi::Mapper
    include ::Cisco::CollaborationEndpoint::UiExtensions
    include ::Cisco::CollaborationEndpoint::ExternalSource

    descriptive_name 'Cisco Room Kit'
    description <<~DESC
        Control of Cisco RoomKit devices.

        API access requires a local user with the 'admin' role to be
        created on the codec.
    DESC

    tokenize delimiter: Tokens::COMMAND_RESPONSE,
             wait_ready: Tokens::LOGIN_COMPLETE
    clear_queue_on_disconnect!

    def connected
        super

        register_feedback '/Event/PresentationPreviewStarted' do
            self[:local_presentation] = true
        end
        register_feedback '/Event/PresentationPreviewStopped' do
            self[:local_presentation] = false
        end

        self[:calls] = {}
        self[:in_call] = false
        register_feedback '/Status/Call' do |call|
            calls = self[:calls].deep_merge call
            calls.reject! do |_, props|
                props[:status] == :Idle || props.include?(:ghost)
            end
            self[:calls] = calls
            self[:in_call] = calls.present?
        end
    end

    status 'Audio Microphones Mute' => :mic_mute
    status 'Audio Volume' => :volume
    status 'Cameras SpeakerTrack' => :speaker_track
    status 'RoomAnalytics PeoplePresence' => :presence_detected
    status 'RoomAnalytics PeopleCount Current' => :people_count
    status 'Conference DoNotDisturb' => :do_not_disturb
    status 'Conference Presentation Mode' => :presentation
    status 'Peripherals ConnectedDevice' => :peripherals
    status 'Video Selfview Mode' => :selfview
    status 'Video Selfview FullScreenMode' => :selfview_fullscreen
    status 'Video Input' => :video_input
    status 'Video Output' => :video_output
    status 'Video Layout LayoutFamily Local' => :video_layout
    status 'Standby State' => :standby

    command 'Audio Microphones Mute' => :mic_mute_on
    command 'Audio Microphones Unmute' => :mic_mute_off
    command 'Audio Microphones ToggleMute' => :mic_mute_toggle
    def mic_mute(state = On)
        is_affirmative? state ? mic_mute_on : mic_mute_off
    end

    command 'Audio Sound Play' => :play_sound,
            Sound: [:Alert, :Bump, :Busy, :CallDisconnect, :CallInitiate,
                    :CallWaiting, :Dial, :KeyInput, :KeyInputDelete, :KeyTone,
                    :Nav, :NavBack, :Notification, :OK, :PresentationConnect,
                    :Ringing, :SignIn, :SpecialInfo, :TelephoneCall,
                    :VideoCall, :VolumeAdjust, :WakeUp],
            Loop_: [:Off, :On]
    command 'Audio Sound Stop' => :stop_sound

    command 'Audio Volume Set' => :volume,
            Level: (0..100)

    command 'Bookings List' => :bookings,
            Days_: (1..365),
            DayOffset_: (0..365),
            Limit_: Integer,
            Offset_: Integer

    command 'Call Accept' => :call_accept, CallId_: Integer
    command 'Call Reject' => :call_reject, CallId_: Integer
    command 'Call Disconnect' => :hangup, CallId_: Integer

    command 'Call DTMFSend' => :dtmf_send,
            DTMFString: String,
            CallId_: (0..65534)

    command 'Dial' => :dial,
            Number:  String,
            Protocol_: [:H320, :H323, :Sip, :Spark],
            CallRate_: (64..6000),
            CallType_: [:Audio, :Video]

    command 'Camera Preset Activate' => :camera_preset,
            PresetId: (1..35)
    command 'Camera Preset Store' => :camera_store_preset,
            CameraId: (1..1),
            PresetId_: (1..35), # Optional - codec will auto-assign if omitted
            Name_: String,
            TakeSnapshot_: [true, false],
            DefaultPosition_: [true, false]

    command 'Camera PositionReset' => :camera_position_reset,
            CameraId: (1..1),
            Axis_: [:All, :Focus, :PanTilt, :Zoom]
    command 'Camera Ramp' => :camera_move,
            CameraId: (1..1),
            Pan_: [:Left, :Right, :Stop],
            PanSpeed_: (1..15),
            Tilt_: [:Down, :Up, :Stop],
            TiltSpeed_: (1..15),
            Zoom_: [:In, :Out, :Stop],
            ZoomSpeed_: (1..15),
            Focus_: [:Far, :Near, :Stop]

    command 'Video Input SetMainVideoSource' => :camera_select,
            ConnectorId_: (1..3),       # Source can either be specified as the
            Layout_: [:Equal, :PIP],    # physical connector...
            SourceId_: (1..3)           # ...or the logical source ID

    command 'Video Layout LayoutFamily Set' => :video_layout,
            LayoutFamily: [:Auto, :Equal, :Overlay, :Prominent, :Single],
            Target_: [:Local, :Remote]

    command 'Video Selfview Set' => :selfview,
            Mode_: [:On, :Off],
            FullScreenMode_: [:On, :Off],
            PIPPosition_: [:CenterLeft, :CenterRight, :LowerLeft, :LowerRight,
                           :UpperCenter, :UpperLeft, :UpperRight],
            OnMonitorRole_: [:First, :Second, :Third, :Fourth]

    command! 'Cameras AutoFocus Diagnostics Start' => \
             :autofocus_diagnostics_start,
             CameraId: (1..1)
    command! 'Cameras AutoFocus Diagnostics Stop' => \
             :autofocus_diagnostics_stop,
             CameraId: (1..1)

    command! 'Cameras SpeakerTrack Diagnostics Start' => \
             :speaker_track_diagnostics_start
    command! 'Cameras SpeakerTrack Diagnostics Stop' => \
             :speaker_track_diagnostics_stop

    command 'Cameras SpeakerTrack Activate' => :speaker_track_activate
    command 'Cameras SpeakerTrack Deactivate' => :speaker_track_deactivate
    def speaker_track(state = On)
        if is_affirmative? state
            speaker_track_activate
        else
            speaker_track_deactivate
        end
    end

    command 'Phonebook Search' => :phonebook_search,
            SearchString: String,
            PhonebookType_: [:Corporate, :Local],
            Limit_: Integer,
            Offset_: Integer

    command 'Presentation Start' => :presentation_start,
            PresentationSource_: (1..2),
            SendingMode_: [:LocalRemote, :LocalOnly],
            ConnectorId_: (1..2),
            Instance_: [:New, *(1..6)]
    command 'Presentation Stop' => :presentation_stop,
            Instance_: (1..6),
            PresentationSource_: (1..2)

    # Provide compatabilty with the router module for activating presentation.
    def switch_to(input)
        if [0, nil, :none, 'none', :blank, 'blank'].include? input
            presentation_stop
        else
            presentation_start presentation_source: input
        end
    end

    command 'Standby Deactivate' => :powerup
    command 'Standby HalfWake' => :half_wake
    command 'Standby Activate' => :standby
    command 'Standby ResetTimer' => :reset_standby_timer, Delay: (1..480)
    def power(state = false)
        if is_affirmative? state
            powerup
        elsif is_negatory? state
            standby
        elsif state.to_s =~ /wake/i
            half_wake
        else
            logger.error "Invalid power state: #{state}"
        end
    end

    command! 'SystemUnit Boot' => :reboot, Action_: [:Restart, :Shutdown]
end
