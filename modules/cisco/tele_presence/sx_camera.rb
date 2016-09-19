load File.expand_path('./sx_telnet.rb', File.dirname(__FILE__))


class Cisco::TelePresence::SxCamera < Cisco::TelePresence::SxTelnet
    descriptive_name 'Cisco TelePresence Camera'
    generic_name :Camera

    tokenize delimiter: "\r",
             wait_ready: "login:"
    clear_queue_on_disconnect!


    def on_load
        # Constants that are made available to interfaces
        self[:pan_speed_max] = 15
        self[:pan_speed_min] = 1
        self[:tilt_speed_max] = 15
        self[:tilt_speed_min] = 1

        # Pan speeds are insane, so we need to keep these values low.
        # In fact we may be forced to use an up down left right key pad
        self[:joy_left] = -3
        self[:joy_right] = 3
        self[:joy_center] = 0

        self[:pan_max] = 65535    # Right
        self[:pan_min] = -65535   # Left
        self[:pan_center] = 0
        self[:tilt_max] = 65535   # UP
        self[:tilt_min] = -65535  # Down
        self[:tilt_center] = 0

        self[:zoom_max] = 17284 # 65535
        self[:zoom_min] = 0

        super

        on_update
    end
    
    def on_update
        @presets = setting(:presets) || {}
        self[:presets] = @presets.keys

        @index = setting(:camera_index) || 1
        self[:camera_index] = @index
    end
    
    def connected
        self[:power] = true

        super

        do_poll
        @polling_timer = schedule.every('30s') do
            logger.debug "-- Polling Camera"
            do_poll
        end
    end
    
    def disconnected
        self[:power] = false

        super

        @polling_timer.cancel unless @polling_timer.nil?
        @polling_timer = nil
    end


    def power(state)
        self[:power]  # Here for compatibility with other camera modules
    end

    def power?(options = nil, &block)
        block.call unless block.nil?
        self[:power]
    end


    def home
        # command("Camera PositionReset CameraId:#{@index}", name: :preset).then do
        # Preset1 is a better home as it will usually pointed to a default position wheras PositionReset may not be a userfull view
        recall_position(1).then do
            autofocus
            do_poll
        end
    end

    def autofocus
        command "Camera TriggerAutofocus CameraId:#{@index}"
    end


    # Absolute position
    def pantilt(pan, tilt)
        pan = in_range(pan.to_i, self[:pan_max], self[:pan_min])
        tilt = in_range(tilt.to_i, self[:tilt_max], self[:tilt_min])

        command('Camera PositionSet', params({
            :CameraId => @index,
            :Pan => pan,
            :Tilt => tilt
        }), name: :pantilt).then do
            self[:pan] = pan
            self[:tilt] = tilt
            autofocus
        end
    end

    def pan(value)
        pan = in_range(value.to_i, self[:pan_max], self[:pan_min])
        command('Camera PositionSet', params({
            :CameraId => @index,
            :Pan => pan
        }), name: :pan).then do
            self[:pan] = pan
            autofocus
        end
    end

    def tilt(value)
        tilt = in_range(value.to_i, self[:tilt_max], self[:tilt_min])
        command('Camera PositionSet', params({
            :CameraId => @index,
            :Tilt => tilt
        }), name: :tilt).then do
            self[:tilt] = tilt
            autofocus
        end
    end

    def zoom(position)
        val = in_range(position.to_i, self[:zoom_max], self[:zoom_min])

        command('Camera PositionSet', params({
            :CameraId => @index,
            :Zoom => val
        }), name: :zoom).then do
            self[:zoom] = val
            autofocus
        end
    end

    def joystick(pan_speed, tilt_speed)
        left_max = self[:joy_left]
        right_max = self[:joy_right]

        pan_speed = in_range(pan_speed.to_i, right_max, left_max)
        tilt_speed = in_range(tilt_speed.to_i, right_max, left_max)

        is_centered = false
        if pan_speed == 0 && tilt_speed == 0
            is_centered = true
        end

        options = {}
        options[:name] = :joystick

        if is_centered
            options[:retries] = 5
            options[:priority] = 99      # Make sure it is executed asap
            options[:clear_queue] = true # Stop executing other commands

            # Request the current position once the stop command
            # has run, we are clearing the queue so we use promises to
            # ensure the pantilt command is executed
            command('Camera Ramp', params({
                :CameraId => @index,
                :Pan => :stop,
                :Tilt => :stop
            }), **options).then do
                autofocus
                pantilt?
            end
        else
            options[:retries] = 0
            
            # Calculate direction
            dir_hori = :stop
            if pan_speed > 0
                dir_hori = :right
            elsif pan_speed < 0
                dir_hori = :left
            end
            
            dir_vert = :stop
            if tilt_speed > 0
                dir_vert = :up
            elsif tilt_speed < 0
                dir_vert = :down
            end

            # Find the absolute speed
            pan_speed = pan_speed * -1 if pan_speed < 0
            tilt_speed = tilt_speed * -1 if tilt_speed < 0

            # Build the request
            cmd = ["Camera Ramp CameraId:#{@index}"]
            if dir_hori == :stop
                cmd << "Pan:stop"
            else
                cmd << params(:Pan => dir_hori, :PanSpeed => pan_speed)
            end

            if dir_vert == :stop
                cmd << "Tilt:stop"
            else
                cmd << params(:Tilt => dir_vert, :TiltSpeed => tilt_speed)
            end
            command *cmd, **options
        end
    end

    def adjust_tilt(direction)
        speed = 0
        if direction == 'down'
            speed = -1
        elsif direction == 'up'
            speed = 1
        end

        joystick(0, speed)
    end

    def adjust_pan(direction)
        speed = 0
        if direction == 'right'
            speed = 1
        elsif direction == 'left'
            speed = -1
        end

        joystick(speed, 0)
    end


    # ---------------------------------
    # Preset Management
    # ---------------------------------
    def preset(name)
        name_sym = name.to_sym
        values = @presets[name_sym]

        if values
            pantilt(values[:pan], values[:tilt])
            zoom(values[:zoom])
            true
        elsif name_sym == :default
            home
        else
            false
        end
    end

    # Recall a preset from the camera
    def recall_position(number)
        number = in_range(number, 15, 1)

        command('Camera PositionActivateFromPreset', params({
            :CameraId => @index,
            :PresetId => number
        }), name: :preset).then do
            autofocus
            do_poll
        end
    end

    def save_position(number)
        number = in_range(number, 15, 1)
        
        command('Camera Preset Store', params({
            :CameraId => @index,
            :PresetId => number
        }))
    end



    # ---------------
    # STATUS REQUESTS
    # ---------------

    def connected?
        status "Camera #{@index} Connected", priority: 0, name: :connected?
    end

    def pantilt?
        status "Camera #{@index} Position Pan", priority: 0, name: :pan?
        status "Camera #{@index} Position Tilt", priority: 0, name: :tilt?
    end

    def zoom?
        status "Camera #{@index} Position Zoom", priority: 0, name: :zoom?
    end

    def manufacturer?
        status "Camera #{@index} Manufacturer", priority: 0, name: :manufacturer?
    end

    def model?
        status "Camera #{@index} Model", priority: 0, name: :model?
    end

    def flipped?
        status "Camera #{@index} Flip", priority: 0, name: :flipped?
    end


    def do_poll
        connected?.then do
            if self[:connected]
                zoom?
                pantilt?
            end
        end
    end

    
    IsResponse = '*s'.freeze
    IsComplete = '**'.freeze
    def received(data, resolve, command)
        logger.debug { "Cam sent #{data}" }

        result = Shellwords.split data

        if command
            if result[0] == IsComplete
                return :success
            elsif result[0] != IsResponse
                return :ignore
            end
        end

        if result[0] == IsResponse
            type = result[3].downcase.gsub(':', '').to_sym

            case type
            when :position
                # Tilt: Pan: Zoom: etc so we massage to our desired status variables
                self[result[4].downcase.gsub(':', '').to_sym] = result[-1].to_i
            when :connected
                self[:connected] = result[-1].downcase == 'true'
            when :model
                self[:model] = result[-1]
            when :manufacturer
                self[:manufacturer] = result[-1]
            when :flip
                # Can be auto/on/off
                self[:flip] = result[-1].downcase != 'off'
            end

            return :ignore
        end
        
        return :success
    end
end

