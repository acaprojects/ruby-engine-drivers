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
        on_update
    end

    def on_update
        @username = setting(:username)
        @password = setting(:password)
    end

    def connected
        login if @username

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



    def get_status(control_id)
        send("cg #{control_id}\n")
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

    def set_value(control_id, value, ramp_time = nil)
        if ramp_time
            send("csvr #{control_id} #{value} #{ramp_time}\n", wait: false)
            schedule.in(ramp_time * 1000 + 200) do
                get_status(control_id)
            end
        else
            send("csv #{control_id} #{value}\n")
        end
    end

    def about
        send "sg", name: :status, priority: 0
    end

    def login(name = @username, password = @password)
        send "login #{name} #{password}\n", name: :login, priority: 99
    end



    # Compatibility Methods
    def fader(fader_id, level)
        faders = fader_id.is_a?(Array) ? fader_id : [fader_id]
        faders.each do |fad|
            set_value(fad, level)
        end
    end

    # Named params version
    def faders(ids:, level:)
        fader(ids, level)
    end


    def preset(name, index, ramp_time = 1.5)
        send "ssl #{name} #{index} #{ramp_time}\n", wait: false
    end

    def save_preset(name, index)
        send "sss #{name} #{index}\n", wait: false
    end



    # -------------------
    # RESPONSE PROCESSING
    # -------------------
    def received(data, resolve, command)
        logger.debug { "QSys sent: #{data}" }

        resp = Shellwords.split(data)
        cmd = resp[0].to_sym

        case cmd
        when :cv
            control_id = resp[1]
            # string rep = resp[2]
            value = resp[3].to_i
            position = resp[4].to_i
            self["#{control_id}_#{index}"] = value
            self["#{control_id}_#{index}_pos"] = position

        when :cvv   # Control status, Array of control status
            control_id = resp[1]
            count = resp[2].to_i

            # Skip strings and extract the values
            next_count = 3 + count
            count = resp[next_count].to_i
            1.upto(count) do |index|
                value = resp[next_count + index]
                self["#{control_id}_#{index}"] = value
            end

            # Grab the positions
            next_count = next_count + count + 1
            count = resp[next_count].to_i
            1.upto(count) do |index|
                value = resp[next_count + index]
                self["#{control_id}_#{index}_pos"] = value
            end

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
            
        else
            logger.warn "Unknown response received #{resp.join(' ')}"
        end

        return :success
    end
end
