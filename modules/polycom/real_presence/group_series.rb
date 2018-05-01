# encoding: ASCII-8BIT
# frozen_string_literal: true

require 'shellwords'

module Polycom; end
module Polycom::RealPresence; end

class Polycom::RealPresence::GroupSeries
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder
    include ::Orchestrator::Security

    # Communication settings
    tokenize delimiter: "\r\n", wait_ready: /Password:/i
    delay between_sends: 200
    tcp_port 24

    # Discovery Information
    descriptive_name 'Polycom RealPresence Group Series'
    generic_name :VidConf


    def on_load
        on_update
    end

    def on_update
        # addrbook (local) commands
        # globaldir (includes LDAP and Skype)
        @use_global_addressbook = setting(:global_addressbook) || true
        @default_content = setting(:default_content) || 2
        @vmr_prefix = setting(:vmr_prefix) || '60'
        @vmr_append = setting(:vmr_append) || ''
    end

    def connected
        # Login
        send "#{setting(:password)}\r", priority: 99

        register
        send "callstate register\r"
        send "mute register\r"
        send "sleep register\r"
        send "vcbutton register\r"
        send "volume register\r"
        send "listen video\r"
        call_info
        schedule.every('50s') do
            logger.debug 'Maintaining connection..'
            call_info
        end
    end

    def disconnected
        schedule.clear
    end

    protect_method :reboot, :reset, :whoami, :unregister, :register
    protect_method :powerdown, :notify, :nonotify

    def reboot
        send "reboot now\r", name: :reboot
    end

    # Requires manual power on once powered down
    def powerdown
        send "powerdown\r"
    end

    def reset
        send "resetsystem\r", name: :reset
    end

    def whoami
        send "whoami\r", name: :whoami
    end

    def unregister
        send "all unregister\r", name: :register
    end

    def register
        send "all register\r", name: :register
    end

    # Lists the notification types that are currently being
    # received, or registers to receive status notifications
    def notify(event)
        send "notify #{event}\r"
    end

    def nonotify(event)
        send "nonotify #{event}\r"
    end

    def answer
        send "answer video\r", name: :answer
    end

    # For cisco compatibility
    def call(action)
        case action.to_sym
        when :accept
            answer
        when :disconnect
            hangup
        end
    end

    def hangup(call_id = nil)
        if call_id
            send "hangup video #{call_id}\r", retries: 0
        else
            send "hangup all\r", name: :hangup_all, retries: 0
        end
    end

    # Monitor1: far|near-or-far|content-or-far|all
    # Monitor2: near|far|content|near-or-far|content-or-near|content-or-far|all
    # Monitor3: rec-all|rec-far-or-near|near|far|content
    def configpresentation(setting, monitor = 1)
        send "configpresentation monitor#{monitor} #{setting}\r"
    end

    def select_camera(index)
        self[:camera_selected] = index
        send "camera near #{index}\r"
    end

    def search(text, count = 30)
        count = count.to_i
        if @use_global_addressbook
            self[:searching] = true
            send "gaddrbook batch search \"#{text}\" \"#{count}\"\r", max_waits: (count + 3), name: :search
        else
            send "addrbook batch search \"#{text}\" \"#{count}\"\r", max_waits: (count + 3), name: :search
        end
    end

    def camera_tracking(state)
        value = is_affirmative?(state) ? 'on' : 'off'
        send "camera near tracking #{value}\r"
    end

    OnOffCMDs = {
        video_mute: 'videomute near',
        audio_mute: 'mute near',
        content_auto: 'contentauto',
        acoustic_fence: 'enableacousticfence',
        audio_add: 'enableaudioadd',
        firewall_traversal: 'enablefirewalltraversal',
        auto_show_content: 'autoshowcontent',
        basic_mode: 'basicmode',
        sip_keepalive: 'enablesipka',
        visual_security: 'enablevisualsecurity',
        display_far_name: 'farnametimedisplay',
        global_directory: 'gdsdirectory',
        generate_tone: 'generatetone',
        lync_directory: 'lyncdirectory',
        near_loop: 'nearloop',
        sleep_mute: 'sleep mute',
        visual_board: 'visualboard',
        visual_board_ppt: 'visualboardppt',
        visual_board_swipe: 'visualboardswipe',
        visual_board_zoom: 'visualboardzoom'
    }

    YesNoCMDs = {
        audio_add: 'enableaudioadd',
        auto_answer: 'autoanswer',
        calendar_play_tone: 'calendarplaytone',
        calendar_register_with_server: 'calendarregisterwithserver',
        calendar_show_private_meetings: 'calendarshowpvtmeetings',
        daylight_savings: 'daylightsavings',
        dynamic_bandwidth: 'dynamicbandwidth',
        echo_canceller: 'echocanceller',
        echo_reply: 'echoreply',
        keyboard_noise_reduction: 'enablekeyboardnoisereduction',
        live_music_mode: 'enablelivemusicmode',
        error_concealment: 'enablepvec',
        resource_reservation: 'enablersvp',
        snmp_enabled: 'enablesnmp',
        encryption: 'encryption',
        far_control_near: 'farcontrolnearcamera',
        h239_enabled: 'h239enable',
        multipoint_auto_answer: 'mpautoanswer',
        mute_auto_answer: 'muteautoanswer'
    }

    LookupCMD = {}
    OnOffCMDs.each do |key, value|
        LookupCMD[value.split(' ')[0]] = key

        define_method key do |enabled|
            enabled = is_affirmative?(enabled) ? 'on' : 'off'
            send "#{value} #{enabled}\r"
        end

        define_method "#{key}?" do
            send "#{value} get\r"
        end
    end
    YesNoCMDs.each do |key, value|
        LookupCMD[value] = key

        define_method key do |enabled|
            enabled = is_affirmative?(enabled) ? 'yes' : 'no'
            send "#{value} #{enabled}\r"
        end

        define_method "#{key}?" do
            send "#{value} get\r"
        end
    end

    GetOnlyCMDs = {
        calendar_status: 'calendarstatus',
        default_gateway: 'defaultgateway',
        calendar_user: 'calendaruser'
    }

    GetOnlyCMDs.each do |key, cmd|
        define_method "#{key}?" do
            send "#{value} get\r"
        end
    end

    SystemSettings = {
        connection_preference: 'connectionpreference',
        dialing_method: 'dialingmethod',
        primary_camera: 'primarycamera',
        camera_content: 'cameracontent',
        camera_content1: 'cameracontent1',
        camera_content2: 'cameracontent2',
        camera_content3: 'cameracontent3',
        display_icons_in_call: 'displayiconsincall',
        enable_poly_commics: 'enablepolycommics',
        line_in_level: 'lineinlevel',
        line_out_mode: 'lineoutmode',
        media_in_level: 'mediainlevel',
        self_view: 'selfview',
        sip_account_name: 'sipaccountname',
        sip_enable: 'sipenable',
        stereo_enable: 'stereoenable',
        transcoding_enabled: 'transcodingenabled',
        web_enabled: 'webenabled'
    }

    LookupSetting = SystemSettings.invert

    SystemSettings.each do |key, cmd|
        define_method key do |value|
            send "systemsetting #{cmd} #{value}\r"
        end

        define_method "#{key}?" do
            send "systemsetting get #{cmd}\r"
        end
    end

    def mute(value)
        audio_mute(value)
    end

    # Valid keys: #|*|0|1|2|3|4|5|6|7|8|9|.
    # down|left|right|select|up
    # back|call|graphics|hangup
    # mute|volume+|volume-|info
    # camera|delete|directory|home|keyboard|menu|period|pip|preset
    def button_press(*keys)
        # succeeded / failed or completed when some keys are not valid
        send "button #{keys.join(' ')}\r"
    end

    def send_DTMF(char)
        send "gendial #{char}\r"
    end

    def video_unmute
        video_mute false
    end

    def volume(value)
        value = in_range(value.to_i, 50)
        send "volume set #{value}\r"
    end

    def fader(fader_id, level, mixer_index = nil)
        volume(level)
    end

    def volume?
        send "volume get\r"
    end

    # VC returns the string of text sent
    def echo(text)
        send "echo \"#{text}\"\r"
    end

    def call_info(call_id = nil)
        if call_id.nil?
            # callinfo begin
            # callinfo:43:Polycom Group Series Demo:192.168.1.101:384:connected:notmuted:outgoing:videocall
            # callinfo end
            send "callinfo all\r", max_waits: 10
        else
            # callinfo:36:192.168.1.102:256:connected:muted:outgoing:videocall
            send "callinfo callid #{call_id}\r", max_waits: 10
        end
    end

    def call_state
        # cs: call[34] speed[384] dialstr[192.168.1.101] state[connected]
        # cs: call[1] inactive
        send "getcallstate\r"
    end

    def dial(number, search = nil)
        if !number.present? && !search.present?
            button_press 'call'
        else
            if number == search
                if number.start_with?(@vmr_prefix) && !number.include?('@')
                    dial_sip "#{number}#{@vmr_append}"
                else
                    dial_sip number
                end
            else
                dial_addressbook number
            end
        end
    end

    def dial_phone(number)
        send "dial phone auto \"#{number}\"\r", name: :dial_phone
    end

    def dial_addressbook(entry)
        send "dial addressbook \"#{entry}\"\r", name: :dial_address
    end

    def dial_addressbook_uid(entry)
        send "dial addressbook_entry #{entry}\r", name: :dial_address
    end

    def dial_sip(number)
        send "dial manual auto \"#{number}\" sip\r", name: :dial_phone
    end

    def multi_point_mode?
        multi_point_mode(:get)
    end

    def multi_point_mode(mode)
        # auto|discussion|presentation|fullscreen
        send "mpmode #{mode}\r"
    end

    def recent_calls
        send "recentcalls\r"
    end

    def sleep_time?
        sleep_time(:get)
    end

    def sleep_time(time)
        # 0|1|3|15|30|60|120|240|480
        send "sleeptime #{time}\r"
    end

    # :none, :remote
    def presentation_mode(action, source = @default_content)
        action = action.to_sym

        # play, stop
        if action == :remote
            auto_show_content(true)
            send "vcbutton #{['play', source].compact.join(' ')}\r"
        else
            auto_show_content(false)
            send "vcbutton stop\r"
        end

        self[:presentation] = action
    end

    def presentation_mode?
        send "vcbutton get\r"
    end

    def quality_preference?
        quality_preference(:get)
    end

    def quality_preference(value)
        # content|people|both
        send "vgaqualitypreference #{value}\r"
    end

    def wake
        send "wake\r"
    end

    def received(response, resolve, command)
        logger.debug { "Polycom sent: #{response}" }

        # Doesn't matter where the event came from
        if response.start_with?('Control event: ')
            response = response.split('Control event: ')[1]
        elsif response == 'system is not in a call'
            self[:call_status] = {}
            return :success
        end

        parts = response.split(/\s|:\s*/)
        return :ignore if parts[0].nil?

        if parts[-1] == 'failed'
            logger.warn "Command failed: #{response}"
            return :abort
        end

        cmd = parts[0].downcase.to_sym

        case cmd
        when :inacall, :autoanswerp2p, :remotecontrol, :microphones,
                :visualboard, :globaldirectory, :ipnetwork, :gatekeeper,
                :sipserver, :logthreshold, :meetingpassword, :rpms
            self[cmd] = parts[1]
        when :model
            self[cmd] = parts[1..-1].join(' ')
        when :serial
            self[cmd] = parts[2] if parts[1] == 'Number'
        when :software
            self[:version] = parts[2] if parts[1] == 'Version'
        when :build
            self[cmd] = parts[2]
        when :notification
            type = parts[1].to_sym
            case type
            when :callstatus
                if parts[2] == 'outgoing'
                    if parts.include?('connecting')
                        # dialing
                    elsif parts.include?('connected')
                        # in call
                    end
                else # incoming

                end
            when :mutestatus
                if parts[2] == 'near'
                    self[:audio_mute] = parts[-1] == 'muted'
                end
            end
        when :mute
            if parts[1] == 'near'
                self[:audio_mute] = parts[-1] == 'on'
            end
        when :mpmode
            self[:multi_point_mode] = parts[1]
        when :sleeptime
            self[:sleep_time] = parts[1].to_i
        when :systemsetting
            key = LookupSetting[parts[1]]
            if key
                self[key] = parts[-1]
            end
        when :vcbutton
            if parts[1] == 'play'
                self[:presentation] = :remote
            elsif parts[1] == 'stop'
                self[:presentation] = :local
            end
        when :vgaqualitypreference
            self[:quality_preference] = parts[1]
        when :volume
            self[:volume] = parts[1].to_i
        when :gaddrbook, :addrbook
            if parts[1][0] == '0'
                self[:searching] = true
                @results = []
                process_result(response)
                return :ignore
            elsif parts[-1] == 'done'
                self[:searching] = false
                self[:search_results] = @results
            else
                process_result(response)
                return :ignore
            end
        when :cs
            # Call state
            # cs: call[34] chan[0] dialstr[192.168.1.103] state[RINGING]
            # cs: call[1] inactive
            if parts[-1] != 'inactive'
                state = parts[-1].split(/\[|\]/)[-1].downcase
                self[:call_status] = {
                    direction: 'unknown', # cisco compat
                    answerstate: state
                }
            end
        when :active
            # We are in a call
            # active: call[34] speed [384]
            self[:call_status] = {
                direction: 'unknown', # cisco compat
                answerstate: 'active'
            }
        when :callinfo
            if parts[1] == 'begin'
                @call_data = String.new
                return :ignore
            elsif parts[1] == 'end'
                if @call_data.include?('connected')
                    if @call_data.include?('outgoing')
                        self[:call_status] = {
                            direction: 'outgoing',
                            answerstate: 'active'
                        }
                    else
                        self[:call_status] = {
                            direction: 'unknown',
                            answerstate: 'active'
                        }
                    end
                end
                @call_data = nil
            else
                @call_data << response
                return :ignore
            end
        when :ended
            # No longer in a call
            # ended: call[34]
            self[:call_status] = {}
        when :listen
            # listen video ringing
            if parts[-1] == 'ringing'
                self[:call_status] = {
                    direction: 'Incoming',
                    answerstate: 'Unanswered'
                }
            end
        when :answered
            # answered: Hang Up
            if parts[1] == 'Hang'
                self[:call_status] = {}
            end
        when :popupinfo
            if parts[1] == 'question'
                self[:popupinfo] = parts[2].downcase
            elsif parts[1] == 'answered'
                self[:popupinfo] = false
            end
        else
            # Assign yes/no and on/off values
            key = LookupCMD[parts[0]]
            if key
                self[key] = is_affirmative?(parts[-1])
            end
        end

        :success
    end

    protected

    def process_result(address)
        parts = address.shellsplit[2..-1]
        name = parts.shift
        @results << {
            name: name,
            number: parts.join(' ')
        }
    end
end
