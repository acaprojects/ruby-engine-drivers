require 'shellwords'
require 'set'

module Qsc; end

# The older V1 protocol
# http://q-syshelp.qschome.com/Content/External%20Control/Q-Sys%20External%20Control/007%20Q-Sys%20External%20Control%20Protocol.htm

class Qsc::QSysControl
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder


    # Discovery Information
    tcp_port 1702
    descriptive_name 'QSC Audio DSP External Control'
    generic_name :Mixer

    # Communication settings
    tokenize delimiter: "\r\n"


    def on_load
        @history = {}
        @change_groups = {}
        @change_group_id = 30

        on_update
    end

    def on_update
        @username = setting(:username)
        @password = setting(:password)
    end

    def connected
        login if @username

        @change_groups.each do |name, group|
            group_id = group[:id]
            controls = group[:controls]

            # Re-create change groups and poll every 2 seconds
            send "cgc #{group_id}\n", wait: false
            send "cgsna #{group_id} 2000\n", wait: false
            controls.each do |id|
                send "cga #{group_id} #{id}\n", wait: false
            end
        end

        @polling_timer = schedule.every('40s') do
            logger.debug "Maintaining Connection"
            about
        end
    end

    def disconnected
        #
        # Disconnected may be called without calling connected
        #    Hence the check if timer is nil here
        #
        @polling_timer.cancel unless @polling_timer.nil?
        @polling_timer = nil
    end



    def get_status(control_id, **options)
        send("cg #{control_id}\n", options)
    end

    def set_position(control_id, position, ramp_time = nil)
        if ramp_time
            send("cspr #{control_id} #{position} #{ramp_time}\n", wait: false)
            schedule.in(ramp_time * 1000 + 200) do
                get_status(control_id)
            end
        else
            send("csp #{control_id} #{position}\n")
        end
    end

    def set_value(control_id, value, ramp_time = nil, **options)
        if ramp_time
            options[:wait] = false
            send("csvr #{control_id} #{value} #{ramp_time}\n", options)
            schedule.in(ramp_time * 1000 + 200) do
                get_status(control_id)
            end
        else
            send("csv #{control_id} #{value}\n", options)
        end
    end

    def about
        send "sg\n", name: :status, priority: 0
    end

    def login(name = @username, password = @password)
        send "login #{name} #{password}\n", name: :login, priority: 99
    end

    # Used to set a dial number / string
    def set_string(control_id, text)
        send "css #{control_id} \"#{text}\"\n"
    end

    # Used to trigger dialing etc
    def trigger(action)
        send "ct #{action}\n", wait: false
    end


    # ---------------------
    # Compatibility Methods
    # ---------------------
    def fader(fader_id, level)
        faders = fader_id.is_a?(Array) ? fader_id : [fader_id]
        faders.each do |fad|
            set_value(fad, level, fader_type: :fader)
        end
    end

    # Named params version
    def faders(ids:, level:)
        fader(ids, level)
    end

    def mute(mute_id, value = true, index = nil)
        level = is_affirmative?(value) ? 1 : 0

        mutes = mute_id.is_a?(Array) ? mute_id : [mute_id]
        mutes.each do |mute|
            set_value(mute, level, fader_type: :mute)
        end
    end

    def mutes(ids:, muted: true, **_)
        mute(ids, muted)
    end

    def unmute(mute_id, index = nil)
        mute(mute_id, false, index)
    end


    def preset(name, index, ramp_time = 1.5)
        send "ssl #{name} #{index} #{ramp_time}\n", wait: false
    end

    def save_preset(name, index)
        send "sss #{name} #{index}\n", wait: false
    end



    # For inter-module compatibility
    def query_fader(fader_id)
        fad = fader_id.is_a?(Array) ? fader_id[0] : fader_id
        get_status(fad, fader_type: :fader)
    end
    # Named params version
    def query_faders(ids:, **_)
        faders = ids.is_a?(Array) ? ids : [ids]
        faders.each do |fad|
            get_status(fad, fader_type: :fader)
        end
    end


    def query_mute(fader_id)
        fad = fader_id.is_a?(Array) ? fader_id[0] : fader_id
        get_status(fad, fader_type: :mute)
    end
    # Named params version
    def query_mutes(ids:, **_)
        faders = ids.is_a?(Array) ? ids : [ids]
        faders.each do |fad|
            get_status(fad, fader_type: :mute)
        end
    end


    # ----------------------
    # Soft phone information
    # ----------------------
    def phone_number(number, control_id)
        set_string control_id, number
    end

    def phone_dial(control_id)
        trigger control_id
        schedule.in 200 do
            poll_change_group :phone
        end
    end

    def phone_hangup(control_id)
        trigger control_id
        schedule.in 200 do
            poll_change_group :phone
        end
    end

    def phone_startup(*ids)
        # Check change group exists
        group = @change_groups[:phone]
        if group.nil?
            group = create_change_group(:phone)
        end

        group_id = group[:id]
        controls = group[:controls]

        # Add ids to change group
        ids.each do |id|
            actual = id.to_s
            if not controls.include? actual
                controls << actual
                send "cga #{group_id} #{actual}\n", wait: false
            end
        end
    end

    def create_change_group(name)
        # Don't recreate if already exists
        name = name.to_sym
        group = @change_groups[name]
        return group if group

        # Provide a unique group id
        next_id = @change_group_id
        @change_group_id += 1

        group = {
            id: next_id,
            controls: Set.new
        }
        @change_groups[name] = group

        # create change group and poll every 2 seconds
        send "cgc #{next_id}\n", wait: false
        send "cgsna #{next_id} 2000\n", wait: false
        group
    end

    def poll_change_group(name)
        group = @change_groups[name.to_sym]
        if group
            send "cgpna #{group[:id]}\n", wait: false
        end
    end



    # -------------------
    # RESPONSE PROCESSING
    # -------------------
    def received(data, resolve, command)
        logger.debug { "QSys sent: #{data}" }
        # rc == will disconnect

        resp = Shellwords.split(data)
        cmd = resp[0].to_sym

        case cmd
        when :cv
            control_id = resp[1]
            # string rep = resp[2]
            value = resp[3].to_i
            position = resp[4].to_i

            self["pos_#{control_id}"] = position

            type = command[:fader_type] || @history[control_id]            
            if type
                @history[control_id] = type

                case type
                when :fader
                    self["fader#{control_id}"] = value
                when :mute
                    self["fader#{control_id}_mute"] = value == 1
                end
            else
                self[control_id] = value
                logger.debug { "Received response from unknown ID type: #{control_id} == #{value}" }
            end

        when :cvv   # Control status, Array of control status
            control_id = resp[1]
            count = resp[2].to_i

            type = command[:fader_type] || @history[control_id]
            if type
                @history[control_id] = type

                # Skip strings and extract the values
                next_count = 3 + count
                count = resp[next_count].to_i
                1.upto(count) do |index|
                    value = resp[next_count + index]

                    case type
                    when :fader
                        self["fader#{control_id}"] = value
                    when :mute
                        self["fader#{control_id}_mute"] = value == 1
                    end
                end
            else
                # Skip strings and extract the values
                next_count = 3 + count
                count = resp[next_count].to_i
                1.upto(count) do |index|
                    value = resp[next_count + index]
                    self[control_id] = value
                end
                logger.debug { "Received response from unknown ID type: #{control_id} == #{value}" }
            end

            # Grab the positions
            next_count = next_count + count + 1
            count = resp[next_count].to_i
            1.upto(count) do |index|
                value = resp[next_count + index]
                self["pos_#{control_id}"] = value
            end

        # About response
        when :sr
            self[:design_name] = resp[1]
            self[:is_primary] = resp[3] == '1'
            self[:is_active] = resp[4] == '1'

        # Error responses
        when :core_not_active, :bad_change_group_handle,
             :bad_command, :bad_id, :control_read_only, :too_many_change_groups

            logger.warn "Error response received: #{resp.join(' ')}"
            return :abort

        when :login_required
            logger.warn "Login is required!"
            login if @username
            return :abort

        when :login_success
            logger.debug 'Login success!'

        when :login_failed
            logger.error 'Invalid login details provided'

        when :rc
            logger.warn "System is notifying us of a disconnect!"

        else
            logger.warn "Unknown response received #{resp.join(' ')}"

        end

        return :success
    end
end
