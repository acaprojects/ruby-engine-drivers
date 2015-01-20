module Axis; end
module Axis::Camera; end


class Axis::Camera::Vapix
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder

    def on_load
        on_update
    end

    def on_update
        defaults({
            delay: 130,
            keepalive: false
        })

        @username = setting(:username)
        unless @username.nil?
            @password = setting(:password)
        end

        self[:pan_max] = 180.0
        self[:pan_min] = -180.0
        self[:pan_center] = 0.0
        self[:tilt_max] = 180.0
        self[:tilt_min] = -180.0
        self[:tilt_center] = 0.0

        self[:joy_left] = -100
        self[:joy_right] = 100
        self[:joy_center] = 0

        self[:zoom_max] = 9999
        self[:zoom_min] = 0

        self[:focus_max] = 9999
        self[:focus_min] = 0

        self[:iris_max] = 9999
        self[:iris_min] = 0

        self[:power] = true
    end

    
    def connected
        schedule.every('60s', method(:do_poll))
        do_poll
    end


    # Here for cross module compatibility
    def power(state = nil, &blk)
        blk.call true
    end

    def pantilt(pan = nil, tilt = nil)
        pt = {
            pan: in_range(pan.to_f, self[:pan_max], self[:pan_min]),
            tilt: in_range(tilt.to_f, self[:tilt_max], self[:tilt_min])
        }
        
        req(:ptz, pt, {name: :pantilt}) do |data, resolve|
            val = extract(data, resolve)
            if val == :success
                self[:pan] = pt[:pan]
                self[:tilt] = pt[:tilt]
                :success
            end
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
            options[:clear_queue] = true
        else
            options[:priority] = 10
            options[:retries] = 0
        end

        logger.debug("Sending camera: #{pan_speed}#{tilt_speed}")

        req(:ptz, "continuouspantiltmove=#{pan_speed},#{tilt_speed}", options) do |data, resolve|
            val = extract(data, resolve)
            if val == :success
                self[:joy_pan] = pan_speed
                self[:joy_tilt] = tilt_speed
                :success
            end
        end
    end


    def zoom(pos)
        pos = in_range(pos.to_i, self[:zoom_max], self[:zoom_min])

        req(:ptz, "zoom=#{pos}", {name: :zoom}) do |data, resolve|
            val = extract(data, resolve)
            if val == :success
                self[:zoom] = pos
                :success
            end
        end
    end


    def focus(pos)
        pos = in_range(pos.to_i, self[:focus_max], self[:focus_min])

        req(:ptz, "focus=#{pos}", {name: :focus}) do |data, resolve|
            val = extract(data, resolve)
            if val == :success
                self[:focus] = pos
                :success
            end
        end
    end

    def auto_focus(state)
        state = is_affirmative?(state) ? 'on' : 'off'
        
        req(:ptz, "autofocus=#{state}", {name: :auto_focus}) do |data, resolve|
            val = extract(data, resolve)
            if val == :success
                self[:auto_focus] = state == 'on'
                :success
            end
        end
    end

    def iris(level)
        level = in_range(level.to_i, self[:iris_max], self[:iris_min])

        req(:ptz, "iris=#{level}", {name: :iris}) do |data, resolve|
            val = extract(data, resolve)
            if val == :success
                self[:iris] = level
                :success
            end
        end
    end

    def auto_iris(state)
        state = is_affirmative?(state) ? 'on' : 'off'
        
        req(:ptz, "autoiris=#{state}", {name: :auto_iris}) do |data, resolve|
            val = extract(data, resolve)
            if val == :success
                self[:auto_iris] = state == 'on'
                :success
            end
        end
    end


    def query_ptz(var)
        req(:ptz, "query=#{var}", {name: "query_#{var}", priority: 0}) do |data, resolve|
            val = extract(data, resolve)
            if val.is_a? Hash
                val.each_pair do |key, value|
                    set_status(key, value)
                end
            end
            :success
        end
    end


    protected


    REQUESTS = {
        ptz: '/axis-cgi/com/ptz.cgi'
    }


    def req(type, params = nil, options = {}, &blk)
        request = REQUESTS[type] || type

        unless @username.nil?
            options[:headers] ||= {}
            options[:headers]['authorization'] = [@username, @password]
        end

        if params.is_a?(Hash) && !params.empty?
            request += '?' # new string object
            params.each do |key, value|
                request << "#{key}=#{value}&"
            end
            request.chop!
        elsif params
            request += "?#{params}"
        end

        get(request, options, &blk)
    end

    def extract(data, resolv)
        body = data[:body].split("\r\n")
        if body.empty?
            resolv.call :success
            logger.debug "empty body = success"
            :success
        elsif body[0] == 'Error:'
            cmd = data[:request]
            logger.warn "Camera error response: #{body[1]} for #{cmd[:path]} #{cmd[:query]}"
            resolv.call(:failed)
            :failed
        else
            resp = {}
            body.each do |line|
                components = line.split('=')
                resp[components[0].to_sym] = components[1]
            end
            logger.debug "returned #{resp}"
            resp
        end
    end

    def do_poll(*args)
        if not self[:limits_configured]
            query_ptz :limits
        end
        query_ptz :position
    end

    def set_status(key, value)
        case key

        # query limits
        when :MinPan
            self[:limits_configured] = true
            self[:pan_min] = value.to_f
        when :MaxPan
            self[:pan_max] = value.to_f
        when :MinTilt
            self[:tilt_min] = value.to_f
        when :MaxTilt
            self[:tilt_max] = value.to_f
        when :MinZoom
            self[:zoom_min] = value.to_i
        when :MaxZoom
            self[:zoom_max] = value.to_i
        when :MinIris
            self[:iris_min] = value.to_i
        when :MaxIris
            self[:iris_max] = value.to_i
        when :MinFocus
            self[:focus_min] = value.to_i
        when :MaxFocus
            self[:focus_max] = value.to_i

        # query position
        when :pan
            self[:pan] = value.to_f
        when :tilt
            self[:tilt] = value.to_f
        when :zoom
            self[:zoom] = value.to_i
        when :autofocus
            self[:autofocus] = value == 'on'
        when :autoiris
            self[:autoiris] = value == 'on'

        # query speed
        when :speed
            self[:speed] = value.to_i
        end
    end
end

