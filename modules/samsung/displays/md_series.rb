module Samsung; end
module Samsung::Displays; end


class Samsung::Displays::MdSeries
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder


    # Discovery Information
    tcp_port 1515
    descriptive_name 'Samsung MD Series LCD'
    generic_name :Display

    # Communication settings
    tokenize indicator: "\xAA", callback: :check_length


    #
    # Control system events
    def on_load
        on_update
        
        self[:volume_min] = 0
        self[:volume_max] = 100
        self[:power] = false

        # Meta data for inquiring interfaces
        self[:type] = :lcd
        self[:input_stable] = true
    end
    
    def on_unload
    end
    
    def on_update
        @id = setting(:display_id) || 0xFF
    end


    #
    # network events
    def connected
        do_poll

        @polling_timer = schedule.every('30s') do
            logger.debug "-- Polling Display"
            do_poll
        end
    end

    def disconnected
        #
        # Disconnected may be called without calling connected
        #   Hence the check if timer is nil here
        #
        self[:power] = false  # As we may need to use wake on lan
        @polling_timer.cancel unless @polling_timer.nil?
        @polling_timer = nil
    end


    #
    # Command types
    COMMAND = {
        :hard_off => 0x11,      # Completely powers off
        :power => 0xF9,         # Technically the panel command
        :volume => 0x12,
        :input => 0x14,
        :mode => 0x18,
        :size => 0x19,
        :pip => 0x3C,           # picture in picture
        :auto_adjust => 0x3D,
        :wall_mode => 0x5C,     # Video wall mode
        :safety => 0x5D,
        :wall_on => 0x84,       # Video wall enabled
        :wall_user => 0x89      # Video wall user control
    }
    COMMAND.merge!(COMMAND.invert)

    # As true power off disconnects the server we only want to
    # power off the panel. This doesn't work in video walls
    # so if a nominal blank input is
    def power(power, broadcast = nil)
        if is_negatory?(power)
            # Blank the screen before turning off panel
            #if self[:power]
            #    blank = setting(:blank)
            #    unless blank.nil?
            #        switch_to blank
            #    end
            #end
            do_send(:power, 1)
        elsif !self[:connected]
            wake(broadcast)
        else
            do_send(:hard_off, 1)
            do_send(:power, 0)
        end
    end

    def hard_off
        do_send(:hard_off, 0)
    end

    def power?(options = {}, &block)
        options[:emit] = block unless block.nil?
        do_send(:power, [], options)
    end


    INPUTS = {
        :vga => 0x14,       # pc in manual
        :dvi => 0x18,
        :dvi_video => 0x1F,
        :hdmi => 0x21,
        :hdmi_pc => 0x22,
        :hdmi2 => 0x23,
        :hdmi2_pc => 0x24,
        :hdmi3 => 0x31,
        :hdmi3_pc => 0x32,
        :display_port => 0x25,
        :dtv => 0x40,
        :media => 0x60,
        :widi => 0x61,
        :magic_info => 0x20
    }
    INPUTS.merge!(INPUTS.invert)

    def switch_to(input, options = {})
        input = input.to_sym if input.class == String
        self[:input_stable] = false
        self[:input_target] = input
        do_send(:input, INPUTS[input], options)
    end

    def volume(vol, options = {})
        vol = vol.to_i
        vol = 0 if vol < 0
        vol = 100 if vol > 100

        do_send(:volume, vol, options)
    end


    #
    # Emulate mute
    def mute_audio(val = true)
        if is_affirmative? val
            if not self[:audio_mute]
                self[:audio_mute] = true
                self[:previous_volume] = self[:volume] || 50
                volume 0
            end
        else
            unmute_audio
        end
    end

    def unmute_audio
        if self[:audio_mute]
            self[:audio_mute] = false
            volume self[:previous_volume]
        end
    end


    #
    # Maintain connection
    def do_poll
        power?({:priority => 0}) do
            if self[:power] == On
                do_send(:volume, [], {:priority => 0})
                do_send(:input, [], {:priority => 0})
            end
        end
    end


    protected


    def wake(broadcast = nil)
        mac = setting(:mac_address)
        if mac
            # config is the database model representing this device
            wake_device(mac, broadcast)
            logger.debug { 
                info = "Wake on Lan for MAC #{mac}"
                info << " directed to VLAN #{broadcast}" if broadcast
                info
            }
        else
            logger.debug { "No MAC address provided" }
        end
    end

    def received(response, resolve, command)
        data = str_to_array(response)
        if data[2] == 3     # Check for correct data length
            status = data[3]
            command = data[4]
            value = data[5]

            if status == 0x41 # 'A'
                case COMMAND[command]
                when :power
                    self[:power] = value == 0
                when :volume
                    self[:volume] = value
                    if self[:audio_mute] && value > 0
                        self[:audio_mute] = false
                    end
                when :input
                    self[:input] = INPUTS[value]
                    if not self[:input_stable]
                        if self[:input_target] == self[:input]
                            self[:input_stable] = true
                        else
                            switch_to(self[:input_target])
                        end
                    end
                end

                return :success
            else
                logger.debug "Samsung failed with: #{byte_to_hex(array_to_str(data))}"
                return :failed  # Failed response
            end
        else
            logger.debug "Samsung aborted with: #{byte_to_hex(array_to_str(data))}"
            return :abort   # unknown result
        end
    end

    # Currently not used. We could check it if we like :)
    def check_checksum(byte_str)
        response = str_to_array(byte_str)
        check = 0
        response[0..-2].each do |byte|
            check = (check + byte) & 0xFF
        end
        response[-1] == check
    end

    # Called by the Abstract Tokenizer
    def check_length(byte_str)
        response = str_to_array(byte_str)
        return false if response.length <= 3

        len = response[2] + 4 # (data length + header and checksum)

        if response.length >= len
            return len
        else
            return false
        end
    end

    # Called by do_send to create a checksum
    def checksum(command)
        check = 0
        command.each do |byte|
            check = (check + byte) & 0xFF
        end
        command << check
    end

    def do_send(command, data = [], options = {})
        data = [data] unless data.is_a?(Array)

        if command.is_a?(Symbol)
            options[:name] = command if data.length > 0     # name unless status request
            command = COMMAND[command]
        end

        data = [command, 0xFF, data.length] + data    # Build request (0xFF is screen id)
        checksum(data)                                # Add checksum
        data = [0xAA] + data                          # Add header
        send(array_to_str(data), options)
    end
end

