module TvOne; end

class TvOne::CorioMaster
    include ::Orchestrator::Constants    # these provide optional helper methods
    include ::Orchestrator::Transcoder   # (not used in this module)


    # Discovery Information
    tcp_port 10001
    descriptive_name 'TV One CORIOmaster video wall'
    generic_name :VideoWall

    # Communication settings
    # tokenize delimiter: "\r\n" # This my guess
    delay between_sends: 150


    def on_load
        on_update
    end
    
    def on_unload
    end
    
    def on_update
        @username = setting(:username) # || default username
        @password = setting(:password) # || default password
    end
    
    def connected
        @polling_timer = schedule.every('60s') do
            logger.debug "-- Polling CORIOmaster"
            send "CORIOmax.Model_Name", priority: 0, name: :name
        end

        login
    end
    
    def disconnected
        # Disconnected will be called before connect if initial connect fails
        @polling_timer.cancel unless @polling_timer.nil?
        @polling_timer = nil
    end

    def login
        if @username
            send "Login(#{@username},#{password})\r\n", priotity: 99
        end
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

    
    protected


    def received(data, resolve, command)
        logger.debug { "CORIO sent: #{data}" }

        :success
    end
end

