# encoding: ASCII-8BIT

module Samsung; end
module Samsung::Displays; end

# Documentation: https://drive.google.com/a/room.tools/file/d/135yRevYnI6BbZvRWjV51Ur0yKU5bQ_a-/view?usp=sharing
# Older Documentation: https://aca.im/driver_docs/Samsung/MDC%20Protocol%202015%20v13.7c.pdf

class Samsung::Displays::MdSeries
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder

    # Discovery Information
    tcp_port 1515
    descriptive_name 'Samsung MD, DM & QM Series LCD'
    generic_name :Display

# Markdown description
description <<-DESC
For DM displays configure the following options:

1. Network Standby = ON
2. Set Auto Standby = OFF
3. Set Eco Solution, Auto Off = OFF

Hard Power off displays each night and hard power ON in the morning.
DESC

    # Communication settings
    tokenize indicator: "\xAA", callback: :check_length
    default_settings display_id: 0

    #
    # Control system events
    def on_load
        on_update

        self[:volume_min] = 0
        self[:volume_max] = 100

        # Meta data for inquiring interfaces
        self[:type] = :lcd
        self[:input_stable] = true
        self[:input_target] ||= :hdmi
        self[:power_stable] = true
    end

    def on_unload
    end

    def on_update
        @id = setting(:display_id) || 0
        @rs232 = setting(:rs232_control) || false
        @blank = setting(:blank)
    end

    #
    # network events
    def connected
        do_poll.then { do_device_config unless self[:hard_off] }

        schedule.every('30s') do
            logger.debug "-- Polling Display"
            do_poll
        end
    end

    def disconnected
        self[:power] = false unless @rs232
        schedule.clear
    end

    #
    # Command types
    COMMAND = {
        :status => 0x00,
        :hard_off => 0x11,      # Completely powers off
        :panel_mute => 0xF9,    # Screen blanking / visual mute
        :volume => 0x12,
        :contrast => 0x24,
        :brightness => 0x25,
        :sharpness => 0x26,
        :colour => 0x27,
        :tint => 0x28,
        :red_gain => 0x29,
        :green_gain => 0x2A,
        :blue_gain => 0x2B,
        :input => 0x14,
        :mode => 0x18,
        :size => 0x19,
        :pip => 0x3C,           # picture in picture
        :auto_adjust => 0x3D,
        :wall_mode => 0x5C,     # Video wall mode
        :safety => 0x5D,
        :wall_on => 0x84,       # Video wall enabled
        :wall_user => 0x89,     # Video wall user control
        :speaker => 0x68,
        :net_standby => 0xB5,   # Keep NIC active in standby
        :eco_solution => 0xE6,  # Eco options (auto power off)
        :auto_power => 0x33,
        :screen_split => 0xB2,  # Tri / quad split (larger panels only)
        :software_version => 0x0E,
        :serial_number => 0x0B
    }
    COMMAND.merge!(COMMAND.invert)

    # As true power off disconnects the server we only want to
    # power off the panel. This doesn't work in video walls
    # so if a nominal blank input is
    def power(power, broadcast = nil)
        power = self[:power_target] = is_affirmative?(power)
        self[:power_stable] = false

        if power == Off
            # Blank the screen before turning off panel if required
            # required by some video walls where screens are chained
            switch_to(@blank) if @blank && self[:power]
            do_send(:panel_mute, 1)
        elsif !@rs232 && !self[:connected]
            wake(broadcast)
        else
            # Power on
            do_send(:hard_off, 1)
            do_send(:panel_mute, 0)
        end
    end

    def hard_off
        do_send(:panel_mute, 0) if self[:power]
        do_send(:hard_off, 0)
        do_poll
    end

    def power?(options = {}, &block)
        options[:emit] = block unless block.nil?
        do_send(:panel_mute, [], options)
    end

    # Adds mute states compatible with projectors
    def mute(state = true)
        should_mute = is_affirmative?(state)
        power(!should_mute)
    end

    def unmute
        power(true)
    end

    #check software version
    def software_version?
        do_send (:software_version)
    end

    def serial_number?
        do_send(:serial_number)
    end

    # ability to send custom mdc commands via backoffice
    def custom_mdc (command, value = "")
        do_send(hex_to_byte(command).bytes[0], hex_to_byte(value).bytes)
    end

    def set_timer(enable = true, volume = 0)
      # set the time on the display
      time_cmd = 0xA7
      time_request = []
      t = Time.now
      time_request << t.day
      hour = t.hour
      ampm = if hour > 12
        hour = hour - 12
        0 # pm
      else
        1 # am
      end
      time_request << hour
      time_request << t.min
      time_request << t.month
      year = t.year.to_s(16).rjust(4, "0")
      time_request << year[0..1].to_i(16)
      time_request << year[2..-1].to_i(16)
      time_request << ampm

      do_send time_cmd, time_request

      state = is_affirmative?(enable) ? '01' : '00'
      vol = volume.to_s(16).rjust(2, '0')
      #              on 03:45 am enabled  off 03:30 am enabled  on-everyday  ignore manual  off-everyday  ignore manual  volume 15  input HDMI   holiday apply
      custom_mdc "A4", "03-2D-01 #{state}  03-1E-01   #{state}      01          80               01           80          #{vol}        21          01"
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
        :hdmi4 => 0x33,
        :hdmi4_pc => 0x34,
        :display_port => 0x25,
        :dtv => 0x40,
        :media => 0x60,
        :widi => 0x61,
        :magic_info => 0x20,
        :whiteboard => 0x64
    }
    INPUTS.merge!(INPUTS.invert)

    def switch_to(input, options = {})
        input = input.to_sym if input.class == String
        self[:input_stable] = false
        self[:input_target] = input
        do_send(:input, INPUTS[input], options)
    end

    SCALE_MODE = {
        fill: 0x09,
        fit:  0x20
    }.tap { |x| x.merge!(x.invert).freeze }

    # Activite the internal compositor. Can either split 3 or 4 ways.
    def split(inputs = [:hdmi, :hdmi2, :hdmi3], layout: 0, scale: :fit, **options)
        main_source = inputs.shift

        data = [
            1,                  # enable
            0,                  # sound from screen section 1
            layout,             # layout mode (1..6)
            SCALE_MODE[scale],  # scaling for main source
            inputs.flat_map do |input|
                input = input.to_sym if input.is_a? String
                [INPUTS[input], SCALE_MODE[scale]]
            end
        ].flatten

        switch_to(main_source, options).then do
            do_send(:screen_split, data, options)
        end
    end

    def volume(vol, options = {})
        vol = in_range(vol.to_i, 100)
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

    Speaker_Modes = {
        internal: 0,
        external: 1
    }
    Speaker_Modes.merge!(Speaker_Modes.invert)
    def speaker_select(mode, options = {})
        do_send(:speaker, Speaker_Modes[mode.to_sym], options)
    end

    #
    # Maintain connection
    def do_poll
        do_send(:status, [], priority: 0).then do
            power? unless self[:hard_off]
        end
    end

    #
    # Enable power on (without WOL)
    def network_standby(enable, options = {})
        state = is_affirmative?(enable) ? 1 : 0
        do_send(:net_standby, state, options)
    end

    #
    # Eco auto power off timer
    def auto_off_timer(enable, options = {})
        state = is_affirmative?(enable) ? 1 : 0
        do_send(:eco_solution, [0x81, state], options)
    end

    #
    # Device auto power control (presumably signal based?)
    def auto_power(enable, options = {})
        state = is_affirmative?(enable) ? 1 : 0
        do_send(:auto_power, state, options)
    end

    #
    # Colour control
    [
        :contrast,
        :brightness,
        :sharpness,
        :colour,
        :tint,
        :red_gain,
        :green_gain,
        :blue_gain
    ].each do |command|
        define_method command do |val, **options|
            val = in_range(val.to_i, 100)
            do_send(command, val, options)
        end
    end


    #
    # Colour control
    [
        :contrast,
        :brightness,
        :sharpness,
        :colour,
        :tint,
        :red_gain,
        :green_gain,
        :blue_gain
    ].each do |command|
        define_method command do |val, **options|
            val = in_range(val.to_i, 100)
            do_send(command, val, options)
        end
    end


    protected


    DEVICE_SETTINGS = [
        :network_standby,
        :auto_off_timer,
        :auto_power,
        :contrast,
        :brightness,
        :sharpness,
        :colour,
        :tint,
        :red_gain,
        :green_gain,
        :blue_gain
    ]
    #
    # Push any configured device settings
    def do_device_config
        logger.debug { "Syncronising device state with settings" }
        DEVICE_SETTINGS.each do |name|
            value = setting(name)
            __send__(name, value) unless value.nil?
        end
    end

    def wake(broadcast = nil)
        mac = setting(:mac_address)
        if mac
            # config is the database model representing this device
            wake_device(mac, broadcast)
            logger.debug {
                info = String.new("Wake on Lan for MAC #{mac}")
                info << " directed to VLAN #{broadcast}" if broadcast
                info
            }
        else
            logger.debug 'No MAC address provided'
        end
    end

    RESPONSE_STATUS = {
        ack: 0x41,
        nak: 0x4e
    }.tap { |x| x.merge!(x.invert).freeze }

    def received(response, resolve, command)
        logger.debug { "Samsung sent #{byte_to_hex(response)}" }

        rx = str_to_array response

        unless rx.pop == (rx.reduce(:+) & 0xFF)
            logger.error 'invalid checksum'
            return :retry
        end

        _, _, _, status, command, *value = rx
        value = value.first if value.length == 1

        case RESPONSE_STATUS[status]
        when :ack
            case COMMAND[command]
            when :status
                self[:hard_off]     = value[0] == 0
                self[:power]        = Off if self[:hard_off]
                self[:volume]       = value[1]
                self[:audio_mute]   = false if value[2] > 0
                self[:input]        = INPUTS[value[3]]
                check_power_state
            when :panel_mute
                self[:power] = value == 0
                check_power_state
            when :volume
                self[:volume] = value
                self[:audio_mute] = false if value > 0
            when :brightness
                self[:brightness] = value
            when :input
                self[:input] = INPUTS[value]
                # The input feedback behaviour seems to go a little odd when
                # screen split is active. Ignore any input forcing when on.
                unless self[:screen_split]
                    self[:input_stable] = self[:input] == self[:input_target]
                    switch_to self[:input_target] unless self[:input_stable]
                end
            when :speaker
                self[:speaker] = Speaker_Modes[value]
            when :hard_off
                was_off = self[:hard_off]
                self[:hard_off] = value == 0
                self[:power] = Off if self[:hard_off]
            when :screen_split
                state = value[0]
                self[:screen_split] = state.positive?
            when :software_version
                self[:software_version] = array_to_str(value)
            when :serial_number
                self[:serial_number] = array_to_str(value)
            else
                logger.debug "Samsung responded with ACK: #{value}"
            end

            byte_to_hex(response)
        when :nak
            logger.warn "Samsung responded with NAK: #{byte_to_hex(Array(value))}"
            :failed  # Failed response
        else
            logger.warn "Samsung aborted with: #{byte_to_hex(Array(value))}"
            byte_to_hex(response)
        end
    end

    def check_power_state
        return if self[:power_stable]
        if self[:power] == self[:power_target]
            self[:power_stable] = true
        else
            power self[:power_target]
        end
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

    def do_send(command, data = [], options = {})
        data = Array(data)

        if command.is_a?(Symbol)
            options[:name] = command if data.length > 0     # name unless status request
            command = COMMAND[command]
        end

        data = [command, @id, data.length] + data     # Build request
        data << (data.reduce(:+) & 0xFF)              # Add checksum
        data = [0xAA] + data                          # Add header

        logger.debug { "Sending to Samsung: #{byte_to_hex(array_to_str(data))}" }

        send(array_to_str(data), options).catch do |reason|
            disconnect
            thread.reject(reason)
        end
    end
end
