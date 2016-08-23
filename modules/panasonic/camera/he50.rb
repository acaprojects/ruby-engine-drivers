module Panasonic; end
module Panasonic::Camera; end


class Panasonic::Camera::He50
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder


    # Discovery Information
    implements :service
    descriptive_name 'Panasonic PTZ Camera HE50/60'
    generic_name :Camera

    # Communication settings
    delay between_sends: 150
    inactivity_timeout 1500
    keepalive false



    def on_load
        self[:pan_max] = 0xD2F5
        self[:pan_min] = 0x2D08
        self[:pan_center] = 0x7FFF
        self[:tilt_max] = 0x8E38
        self[:tilt_min] = 0x5556
        self[:tilt_center] = 0x7FFF

        self[:joy_left] = 0x01
        self[:joy_right] = 0x99
        self[:joy_center] = 0x50

        self[:zoom_max] = 0xFFF
        self[:zoom_min] = 0x555

        self[:focus_max] = 0xFFF
        self[:focus_min] = 0x555

        self[:iris_max] = 0xFFF
        self[:iris_min] = 0x555
        
        on_update
    end

    def on_update
        # {near: {zoom: val, pan: val, tilt: val}}
        @presets = setting(:presets) || {}
        self[:presets] = @presets.keys
    end
    
    def connected
        schedule.every('60s', method(:do_poll))
        do_poll
    end


    RESP = {
        power: 'p',
        installation: 'iNS',

        pantilt: 'aPC',
        joystick: 'pTS',
        limit: 'lC',

        zoom: /axz|gz/,
        manual_zoom: 'zS',
        link_zoom: 'sWZ',

        focus: /axf|gf/,
        manual_focus: 'fS',
        auto_focus: 'd1',

        iris: /axi|gi/,
        auto_iris: 'd3'
    }
    LIMITS = {
        up: 1,
        down: 2,
        left: 3,
        right: 4
    }
    LIMITS.merge!(LIMITS.invert)


    # Responds with:
    # 0 == standby
    # 1 == power on
    # 3 == powering on
    def power(state = nil, &blk)
        state = (is_affirmative?(state) ? 1 : 0) unless state.nil?

        options = {}
        options[:emit] = blk if blk
        options[:delay] = 6000 if state

        logger.debug "Camera requested power #{state}"
        
        req('O', state, :power, options) do |data, resolve|
            val = extract(:power, data, resolve)
            if val
                self[:power] = val.to_i > 0
                :success
            end
        end
    end

    def installation(pos = nil)
        pos = (pos.to_sym == :desk ? 0 : 1) if pos
        
        req('INS', pos, :installation) do |data, resolve|
            val = extract(:installation, data, resolve)
            if val
                self[:installation] = val == '0' ? :desk : :ceiling
                :success
            end
        end
    end

    def pantilt(pan = nil, tilt = nil)
        unless pan.nil?
            pan = in_range(pan.to_i, self[:pan_max], self[:pan_min]).to_s(16).upcase.rjust(4, '0')
            tilt = in_range(tilt.to_i, self[:tilt_max], self[:tilt_min]).to_s(16).upcase.rjust(4, '0')
        end
        
        req('APC', "#{pan}#{tilt}", :pantilt) do |data, resolve|
            val = extract(:pantilt, data, resolve)
            if val
                comp = []
                val.scan(/.{4}/) { |com| comp << com.to_i(16) }
                self[:pan] = comp[0]
                self[:tilt] = comp[1]
                :success
            end
        end
    end

    # Recall a preset from the database
    def preset(name)
        values = @presets[name.to_sym]
        if values
            pantilt(values[:pan], values[:tilt])
            zoom(values[:zoom])
            true
        else
            false
        end
    end

    def joystick(pan_speed, tilt_speed)
        pan_speed ||= self[:joy_center]
        tilt_speed ||= self[:joy_center]

        left_max = self[:joy_left]
        right_max = self[:joy_right]
        pan_speed = in_range(pan_speed.to_i, right_max, left_max).to_s(16).upcase.rjust(2, '0')
        tilt_speed = in_range(tilt_speed.to_i, right_max, left_max).to_s(16).upcase.rjust(2, '0')

        is_centered = false
        if pan_speed == '50' && tilt_speed == '50'
            is_centered = true
        end

        options = {}
        options[:retries] = is_centered ? 1 : 0

        logger.debug("Sending camera: #{pan_speed}#{tilt_speed}");

        req('PTS', "#{pan_speed}#{tilt_speed}", :joystick, options) do |data, resolve|
            val = extract(:joystick, data, resolve)
            if val
                comp = []
                val.scan(/.{2}/) { |com| comp << com.to_i(16) }
                self[:joy_pan] = comp[0]
                self[:joy_tilt] = comp[1]
                :success
            end
        end
    end

    def adjust_tilt(direction)
        speed = 0x50
        if direction == 'down'
            speed = 0x75
        elsif direction == 'up'
            speed = 0x25
        end

        joystick(0x50, speed)
    end

    def adjust_pan(direction)
        speed = 0x50
        if direction == 'right'
            speed = 0x75
        elsif direction == 'left'
            speed = 0x25
        end

        joystick(speed, 0x50)
    end

    def limit(direction, state = nil)
        dir = LIMITS[direction.to_sym]
        state = (is_affirmative?(set) ? 1 : 0) unless state.nil?

        req('LC', "#{dir}#{state}", :limit) do |data, resolve|
            val = extract(:limit, data, resolve)
            if val
                self[:"limit_#{LIMITS[val[0].to_i]}"] = val[1] == '1'
                :success
            end
        end
    end


    def zoom(pos = nil)
        cmd = 'AXZ'
        if pos
            pos = in_range(pos.to_i, self[:zoom_max], self[:zoom_min]).to_s(16).upcase.rjust(3, '0')
        else
            cmd = 'GZ'
        end

        req(cmd, pos, :zoom) do |data, resolve|
            val = extract(:zoom, data, resolve)
            if val
                self[:zoom] = val.to_i(16)
                :success
            end
        end
    end

    def manual_zoom(speed)
        speed = in_range(speed.to_i, self[:joy_right], self[:joy_left]).to_s(16).upcase.rjust(3, '0')

        req('Z', speed, :manual_zoom) do |data, resolve|
            val = extract(:manual_zoom, data, resolve)
            if val
                self[:manual_zoom] = val.to_i(16)
                :success
            end
        end
    end

    def link_zoom(state = nil) # Link pantilt speed to zoom
        state = (is_affirmative?(state) ? 1 : 0) unless state.nil?
        
        req('SWZ', state, :link_zoom) do |data, resolve|
            val = extract(:link_zoom, data, resolve)
            if val
                self[:link_zoom] = val == '1'
                :success
            end
        end
    end


    def focus(pos = nil)
        cmd = 'AXF'
        if pos
            pos = in_range(pos.to_i, self[:focus_max], self[:focus_min]).to_s(16).upcase.rjust(3, '0')
        else
            cmd = 'GF'
        end

        req(cmd, pos, :focus) do |data, resolve|
            val = extract(:focus, data, resolve)
            if val
                self[:focus] = val.to_i(16)
                :success
            end
        end
    end

    def manual_focus(speed)
        speed = in_range(speed.to_i, self[:joy_right], self[:joy_left]).to_s(16).upcase.rjust(2, '0')

        req('F', speed, :manual_focus) do |data, resolve|
            val = extract(:manual_focus, data, resolve)
            if val
                self[:manual_focus] = val.to_i(16)
                :success
            end
        end
    end

    def auto_focus(state = nil)
        state = (is_affirmative?(state) ? 1 : 0) unless state.nil?
        
        req('D1', state, :auto_focus) do |data, resolve|
            val = extract(:auto_focus, data, resolve)
            if val
                self[:auto_focus] = val == '1'
                :success
            end
        end
    end


    def iris(level = nil)
        cmd = 'AXI'
        if level
            level = in_range(level.to_i, self[:iris_max], self[:iris_min]).to_s(16).upcase.rjust(3, '0')
        else
            cmd = 'GI'
        end

        req(cmd, level, :iris) do |data, resolve|
            val = extract(:iris, data, resolve)
            if val
                self[:iris] = val[0..2].to_i(16)
                if val.length == 4
                    self[:auto_iris] = val == '1'
                end
                :success
            end
        end
    end

    def auto_iris(state = nil)
        state = (is_affirmative?(state) ? 1 : 0) unless state.nil?
        
        req('D3', state, :auto_iris) do |data, resolve|
            val = extract(:auto_iris, data, resolve)
            if val
                self[:auto_iris] = val == '1'
                :success
            end
        end
    end


    protected


    def req(cmd, data, name, options = {}, &blk)
        if data.nil? || (data.respond_to?(:empty?) && data.empty?)
            options[:delay] = 0
            options[:priority] = 0 # Actual commands have a higher priority
        else
            options[:name] = name
        end
        request_string = "/cgi-bin/aw_ptz?cmd=%23#{cmd}#{data}&res=1"
        get(request_string, options, &blk)

        logger.debug "requesting #{name}: #{request_string}"
    end

    def extract(name, data, resp)
        logger.debug "received #{data} for command #{name}"

        body = data[:body]
        if body[0] == 'e'
            notify_error(body, 'invalid command sent', data)
            resp.call(:failed)
            nil
        else
            body.sub(RESP[name], '')
        end
    end

    def do_poll(*args)
        power do
            if self[:power] # only request status if online
                pantilt
                zoom
            end
        end
    end

    def notify_error(err, msg, cmd)
        cmd = cmd[:request]
        logger.warn "Camera error response: #{err} - #{msg} for #{cmd[:path]} #{cmd[:query]}"
    end
end

