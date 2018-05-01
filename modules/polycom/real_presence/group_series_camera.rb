# encoding: ASCII-8BIT
# frozen_string_literal: true

module Polycom; end
module Polycom::RealPresence; end

class Polycom::RealPresence::GroupSeriesCamera
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder
    include ::Orchestrator::Security

    # Communication settings
    tokenize delimiter: "\r\n", wait_ready: /Password:/i
    delay between_sends: 200
    tcp_port 24

    # Discovery Information
    descriptive_name 'Polycom RealPresence Group Camera'
    generic_name :Camera


    def on_load
        self[:joy_left] = -1
        self[:joy_right] = 1
        self[:joy_center] = 0

        self[:pan_max] = 50000    # Right
        self[:pan_min] = -50000   # Left
        self[:pan_center] = 0
        self[:tilt_max] = 50000   # UP
        self[:tilt_min] = -50000  # Down
        self[:tilt_center] = 0

        self[:zoom_max] = 50000 # 65535
        self[:zoom_min] = -50000

        on_update
    end

    def on_update
        # {near: {zoom: val, pan: val, tilt: val}}
        @presets = setting(:presets) || {}
        self[:presets] = @presets.keys

        @index = setting(:camera_index) || 1
        @home_pos = setting(:home_position) || 1
    end

    def connected
        # Login
        send "#{setting(:password)}\r", priority: 99

        send "preset register\r"
        status
        position?

        schedule.every('50s') do
            logger.debug 'Maintaining connection..'
            maintain_connection
        end
    end

    def disconnected
        schedule.clear
    end

    protect_method :notify, :nonotify, :update_position, :send_cmd, :maintain_connection

    def send_cmd(data)
        logger.debug { "sending: #{data}" }
        send "#{data}\r"
    end

    def power(state)
        # no-op
    end

    def maintain_connection
        # Queries the AMX beacon state.
        send "amxdd get\r", name: :connection_maintenance, priority: 0
    end

    # Lists the notification types that are currently being
    # received, or registers to receive status notifications
    def notify(event)
        send "notify #{event}\r"
    end

    def nonotify(event)
        send "nonotify #{event}\r"
    end

    def status
        send "status\r"
    end

    def tracking?
        send "camera near tracking get\r"
    end

    def tracking(enabled = true)
        setting = is_affirmative?(enabled) ? 'on' : 'off'
        send "camera near tracking #{setting}\r"
    end

    # Absolute position
    def pantilt(pan, tilt)
        pan = in_range(pan.to_i, self[:pan_max], self[:pan_min])
        tilt = in_range(tilt.to_i, self[:tilt_max], self[:tilt_min])

        self[:pan] = pan
        self[:tilt] = tilt
        update_position
    end

    def pan(value)
        pan = in_range(value.to_i, self[:pan_max], self[:pan_min])
        self[:pan] = pan
        update_position
    end

    def tilt(value)
        tilt = in_range(value.to_i, self[:tilt_max], self[:tilt_min])
        self[:tilt] = tilt
        update_position
    end

    def zoom(position)
        val = in_range(position.to_i, self[:zoom_max], self[:zoom_min])
        self[:zoom] = val
        update_position
    end

    def update_position
        send "camera near setposition \"#{self[:pan]}\" \"#{self[:tilt]}\" \"#{self[:zoom]}\"\r"
    end

    def position?
        send "camera near getposition\r", priority: 0
    end

    def select_camera(index)
        send "camera near #{index}\r"
        schedule.in(500) { position? }
    end

    # up, down, stop
    def adjust_tilt(direction)
        send "camera near move #{direction}\r"
        position? if direction == 'stop'
    end

    # right, left, stop
    def adjust_pan(direction)
        send "camera near move #{direction}\r"
        position? if direction == 'stop'
    end

    def home
        recall_position @home_pos
    end

    # ---------------------------------
    # Preset Management
    # ---------------------------------
    def preset(name)
        return recall_position(name) if name.is_a?(Integer)

        name_sym = name.to_sym
        value = @presets[name_sym]

        if value && value.is_a?(Integer)
            recall_position value
            true
        elsif value
            self[:pan] = values[:pan] || self[:pan]
            self[:tilt] = values[:tilt] || self[:tilt]
            self[:zoom] = values[:zoom] || self[:zoom]
            update_position
        elsif name_sym == :default
            home
        else
            false
        end
    end

    def save_preset(name)
        position?.then do
            @presets[name] = {
                zoom: self[:zoom],
                pan: self[:pan],
                tilt: self[:tilt]
            }
            define_setting(:presets, @presets)
            self[:presets] = @presets.keys
        end
    end

    # Recall a preset from the camera
    def recall_position(number, site: :near)
        send "preset #{site} go #{number}\r", delay: 1000
        position?
    end

    def save_position(number, site: :near)
        send "preset #{site} set #{number}\r"
    end

    def received(response, resolve, command)
        logger.debug { "Polycom sent #{response}" }

        # Ignore the echo
        #if command && command[:wait_count] == 0
        #    return :ignore
        #end

        # Break up the message
        parts = response.split(/\s|:\s*/)
        return :ignore if parts[0].nil?

        cmd = parts[0].downcase.to_sym

        case cmd
        when :inacall, :autoanswerp2p, :remotecontrol, :microphones,
                :visualboard, :globaldirectory, :ipnetwork, :gatekeeper,
                :sipserver, :logthreshold, :meetingpassword, :rpms
            self[cmd] = parts[1]
        when :model
            self[cmd] = parts[1..-1].join(' ')
        when :serial
            self[cmd] = parts[2] if parts[1] == 'Number'
        when :software
            self[:version] = parts[2] if parts[1] == 'Version'
        when :build
            self[cmd] = parts[2]
        when :camera
            return :ignore if parts[1] == 'far'
            if parts[2] == 'position'
                self[:pan] = parts[3].to_i
                self[:tilt] = parts[4].to_i
                self[:zoom] = parts[5].to_i
            end
        when :preset
            if parts[1] == 'near' && parts[2] == 'go'
                self[:preset_number] = parts[3].to_i
                schedule.in(500) { position? }
            end
        end

        :success
    end
end
