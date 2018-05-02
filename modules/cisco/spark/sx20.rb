# frozen_string_literal: true

load File.join(__dir__, 'room_os.rb')
load File.join(__dir__, 'ui_extensions.rb')
load File.join(__dir__, 'external_source.rb')

class Cisco::Spark::Sx20 < Cisco::Spark::RoomOs
    include ::Cisco::Spark::Xapi::Mapper
    include ::Cisco::Spark::UiExtensions
    include ::Cisco::Spark::ExternalSource

    descriptive_name 'Cisco Spark SX20'
    description <<~DESC
        Device access requires an API user to be created on the endpoint.
    DESC

    tokenize delimiter: Tokens::COMMAND_RESPONSE,
             wait_ready: Tokens::LOGIN_COMPLETE
    clear_queue_on_disconnect!

    status 'Audio Microphones Mute' => :mic_mute
    status 'Audio Volume' => :volume
    status 'RoomAnalytics PeoplePresence' => :presence_detected
    status 'Conference DoNotDisturb' => :do_not_disturb
    status 'Conference Presentation Mode' => :presentation
    status 'Peripherals ConnectedDevice' => :peripherals
    status 'SystemUnit State NumberOfActiveCalls' => :active_calls
    status 'Video SelfView Mode' => :selfview
    status 'Video Input' => :video_input
    status 'Video Output' => :video_output
    status 'Standby State' => :standby

    command 'Audio Microphones Mute' => :mic_mute_on
    command 'Audio Microphones Unmute' => :mic_mute_off
    command 'Audio Microphones ToggleMute' => :mic_mute_toggle

    command 'Audio Sound Play' => :play_sound,
            Sound: [:Alert, :Bump, :Busy, :CallDisconnect, :CallInitiate,
                    :CallWaiting, :Dial, :KeyInput, :KeyInputDelete, :KeyTone,
                    :Nav, :NavBack, :Notification, :OK, :PresentationConnect,
                    :Ringing, :SignIn, :SpecialInfo, :TelephoneCall,
                    :VideoCall, :VolumeAdjust, :WakeUp],
            Loop_: [:Off, :On]
    command 'Audio Sound Stop' => :stop_sound

    command 'Call Disconnect' => :hangup, CallId_: Integer
    command 'Dial' => :dial,
            Number:  String,
            Protocol_: [:H320, :H323, :Sip, :Spark],
            CallRate_: (64..6000),
            CallType_: [:Audio, :Video]

    command 'Camera PositionReset' => :camera_position_reset,
            CameraId: (1..2),
            Axis_: [:All, :Focus, :PanTilt, :Zoom]
    command 'Camera Ramp' => :camera_move,
            CameraId: (1..2),
            Pan_: [:Left, :Right, :Stop],
            PanSpeed_: (1..15),
            Tilt_: [:Down, :Up, :Stop],
            TiltSpeed_: (1..15),
            Zoom_: [:In, :Out, :Stop],
            ZoomSpeed_: (1..15),
            Focus_: [:Far, :Near, :Stop]

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
