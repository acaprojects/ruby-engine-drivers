# encoding: ASCII-8BIT

module Sony; end
module Sony::Camera; end

# Documentation: https://aca.im/driver_docs/Sony/sony-camera-CGI-Commands-1.pdf

class Sony::Camera::CGI
    include ::Orchestrator::Constants    # these provide optional helper methods
    include ::Orchestrator::Transcoder   # (not used in this module)

    # Discovery Information
    descriptive_name "Sony Camera HTTP CGI Protocol"
    generic_name :Camera
    implements :service
    keepalive false

    default_settings({
      username: "admin",
      password: "Admin_1234",
      invert: false,
      presets: {
        name: { pan: 1, tilt: 1, zoom: 1 }
      }
    })

    def on_load
        # Constants that are made available to interfaces
        self[:joy_left] =  -100
        self[:joy_right] = 100
        self[:joy_center] = 0

        @moving = false
        @max_speed = 1

        schedule.every('60s') do
            logger.debug "-- Polling Sony Camera"
            query_status
        end

        on_update
    end

    def on_update
        @presets = setting(:presets) || {}
        self[:presets] = @presets.keys
        self[:invert] = @invert = setting(:invert) || false
        @authorization = [setting(:username), setting(:password)]
    end

    def connected
        query_status
    end

    def query_status(priority = 0)
        query("/command/inquiry.cgi?inq=ptzf", priority: priority) do |response|
            response.each do |key, value|
                case key
                when "AbsolutePTZF"
                    #              Pan,  Tilt, Zoom,Focus
                    # AbsolutePTZF=15400,fd578,0000,ca52
                    parts = value.split(",")
                    self[:pan] = @pan = twos_complement(parts[0].to_i(16))
                    self[:tilt] = @tilt = twos_complement(parts[1].to_i(16))
                    self[:zoom] = @zoom = twos_complement(parts[2].to_i(16))

                when "PanPanoramaRange"
                    # PanMovementRange=eac00,15400
                    parts = value.split(",")
                    pan_min = twos_complement parts[0].to_i(16)
                    pan_max = twos_complement parts[1].to_i(16)

                    @pan_range = (pan_min..pan_max)
                    self[:pan_range] = {min: pan_min, max: pan_max}
                    self[:pan_max] = pan_max    # Right
                    self[:pan_min] = pan_min     # Left

                when "TiltPanoramaRange"
                    # TiltMovementRange=fc400,b400
                    parts = value.split(",")
                    tilt_min = twos_complement parts[0].to_i(16)
                    tilt_max = twos_complement parts[1].to_i(16)

                    @tilt_range = (tilt_min..tilt_max)
                    self[:tilt_range] = {min: tilt_min, max: tilt_max}
                    self[:tilt_max] = tilt_max   # UP
                    self[:tilt_min] = tilt_min   # Down

                when "ZoomMovementRange"
                    #                    min, max, digital
                    # ZoomMovementRange=0000,4000,7ac0
                    parts = value.split(",")
                    zoom_min = twos_complement parts[0].to_i(16)
                    zoom_max = twos_complement parts[1].to_i(16)
                    @zoom_range = (zoom_min..zoom_max)
                    self[:zoom_range] = {min: zoom_min, max: zoom_max}
                    self[:zoom_min] = zoom_min
                    self[:zoom_max] = zoom_max

                when "PtzfStatus"
                    # PtzfStatus=idle,idle,idle,idle
                    parts = value.split(",")[0..2]
                    self[:moving] = @moving = parts.include?("moving")

                    # when "AbsoluteZoom"
                    #  # AbsoluteZoom=609
                    #  self[:zoom] = @zoom = value.to_i(16)

                    # NOTE:: These are not required as speeds are scaled
                    #
                    # when "ZoomMaxVelocity"
                    #  # ZoomMaxVelocity=8
                    #  @zoom_speed = 1..value.to_i(16)

                when "PanTiltMaxVelocity"
                    # PanTiltMaxVelocity=24
                    @max_speed = value.to_i(16)
                end
            end
        end
    end

    def info?
        query("/command/inquiry.cgi?inq=system", priority: 0) do |response|
            keys = ["ModelName", "Serial", "SoftVersion", "ModelForm", "CGIVersion"]
            response.each do |key, value|
                if keys.include?(key)
                    self[key.underscore] = value
                end
            end
        end
    end

    # Absolute position
    def pantilt(pan, tilt, zoom = nil)
        pan = twos_complement in_range(pan.to_i, @pan_range.end, @pan_range.begin)
        tilt = twos_complement in_range(tilt.to_i, @tilt_range.end, @tilt_range.begin)

        if zoom
            zoom = twos_complement in_range(zoom.to_i, @zoom_range.end, @zoom_range.begin)

            action("/command/ptzf.cgi?AbsolutePTZF=#{pan.to_s(16)},#{tilt.to_s(16)},#{zoom.to_s(16)}",
              name: "position"
            ) do
                self[:pan] = @pan = pan
                self[:tilt] = @tilt = tilt
                self[:zoom] = @zoom = zoom
            end
        else
            action("/command/ptzf.cgi?AbsolutePanTilt=#{pan.to_s(16)},#{tilt.to_s(16)},#{@max_speed.to_s(16)}",
              name: "position"
            ) do
                self[:pan] = @pan = pan
                self[:tilt] = @tilt = tilt
            end
        end
    end

    def joystick(pan_speed, tilt_speed)
        range = -100..100
        pan_speed = in_range(pan_speed.to_i, range.end, range.begin)
        tilt_speed = in_range(tilt_speed.to_i, range.end, range.begin)
        is_centered = pan_speed == 0 && tilt_speed == 0

        tilt_speed = -tilt_speed if @invert && tilt_speed != 0

        if is_centered
            action("/command/ptzf.cgi?Move=stop,motor,image1",
                priority: 999,
                name: "moving"
            ) do
                self[:moving] = @moving = false
                query_status
            end
        else
            action("/command/ptzf.cgi?ContinuousPanTiltZoom=#{pan_speed.to_s(16)},#{tilt_speed.to_s(16)},0,image1",
                name: "moving"
            ) do
                self[:moving] = @moving = true
            end
        end
    end

    def zoom(position)
        position = in_range(position.to_i, @zoom_range.end, @zoom_range.begin)

        action("/command/ptzf.cgi?AbsoluteZoom=#{position.to_s(16)}",
            name: "zooming"
        ) { self[:zoom] = @zoom = position }
    end

    def move(position)
      position = position.to_s.downcase
      case position
      when 'up', 'down', 'left', 'right'
          # Tilt, Pan
          if @invert && ['up', 'down'].include?(position)
              position = position == 'up' ? 'down' : 'up'
          end

          speed = (@max_speed.to_f * 0.5).to_i

          action("/command/ptzf.cgi?Move=#{position},#{speed.to_s(16)},image1",
              name: "moving"
          ) { self[:moving] = @moving = true }
      when 'stop'
          joystick(0, 0)
      else
          raise "unsupported direction: #{position}"
      end
    end

    def adjust_tilt(direction)
        direction = direction.to_s.downcase
        if ['up', 'down'].include?(direction)
            move(direction)
        else
            joystick(0, 0)
        end
    end

    def adjust_pan(direction)
      direction = direction.to_s.downcase
      if ['left', 'right'].include?(direction)
          move(direction)
      else
          joystick(0, 0)
      end
    end

    def home
      action("/command/presetposition.cgi?HomePos=ptz-recall",
          name: "position"
      ) { query_status }
    end

    # Recall a preset from the database
    def preset(name)
        name_sym = name.to_sym
        values = @presets[name_sym]
        if values
            pantilt(values[:pan], values[:tilt], values[:zoom])
            true
        elsif name_sym == :default
            home
        else
            false
        end
    end

    # Recall a preset from the camera
    def recall_position(number)
        preset number.to_s
    end

    def save_position(name)
        name = name.to_s
        logger.debug { "saving preset #{name} - pan: #{pan}, tilt: #{tilt}, zoom: #{zoom}" }
        @presets[name] = {
            pan: pan,
            tilt: tilt,
            zoom: zoom
        }
        self[:presets] = @presets.keys
        define_setting(:presets, @presets)
        self[:presets]
    end


    protected


    # 16bit twos complement
    def twos_complement(value)
      if value > 0
        value > 0x8000 ? -(((~(value & 0xFFFF)) + 1) & 0xFFFF) : value
      else
        ((~(-value & 0xFFFF)) + 1) & 0xFFFF
      end
    end

    def query(path, **options)
        options[:headers] ||= {}
        options[:headers]['authorization'] = @authorization

        get(path, options) do |response|
            raise "unexpected response #{response.status}\n#{response.body}" unless response.status == 200

            state = {}
            response.body.split("&").each do |key_value|
                parts = key_value.strip.split("=")
                state[parts[0]] = parts[1]
            end

            yield state
            state
        end
    end

    def action(path, **options)
        options[:headers] ||= {}
        options[:headers]['authorization'] = @authorization

        get(path, options) do |response|
            raise "request error #{response.status}\n#{response.body}" unless response.status == 200
            yield response
            :success
        end
    end
end
