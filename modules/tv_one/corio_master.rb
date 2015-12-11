module TvOne; end

class TvOne::CorioMaster
    include ::Orchestrator::Constants    # these provide optional helper methods
    include ::Orchestrator::Transcoder   # (not used in this module)


    # Discovery Information
    tcp_port 10001
    descriptive_name 'TV One CORIOmaster video wall'
    generic_name :VideoWall

    # Communication settings
    tokenize delimiter: "\r\n", wait_ready: "Interface Ready"
    delay between_sends: 150


    def on_load
        on_update
    end
    
    def on_unload
    end
    
    def on_update
        @username = setting(:username) || 'admin'
        @password = setting(:password) || 'adminpw'
    end
    
    def connected
        @polling_timer = schedule.every('60s') do
            logger.debug "-- Polling CORIOmaster"

            # Get the current preset
            preset
        end

        login
    end
    
    def disconnected
        # Disconnected will be called before connect if initial connect fails
        @polling_timer.cancel unless @polling_timer.nil?
        @polling_timer = nil
    end

    def login
        send "login(#{@username},#{@password})\r\n", priotity: 99
    end

    def reboot
        send "System.Reset()\r\n"
    end

    def preset(number = nil)
        if number
            send "Preset.Take = #{number}\r\n", name: :preset
        else
            send "Preset.Take\r\n"
        end
    end

    # Runs any command provided
    def send_command(cmd)
        send "#{cmd}\r\n", wait: false
    end

    
    protected


    def received(data, resolve, command)
        if data[1..5] == 'Error'
            logger.warn "CORIO error: #{data}"

            # Attempt to login if we are not currently
            if data =~ /Not Logged In/i
                login
            end

            return :abort if command
        else
            logger.debug { "CORIO sent: #{data}" }
        end

        if command
            if data[0] == '!'
                result = data.split(' ')
                case result[0].to_sym
                when :"Preset.Take"
                    self[:preset] = result[-1].to_i
                end

                :success
            else
                :ignore
            end
        else
            :success
        end
    end
end

