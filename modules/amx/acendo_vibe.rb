# encoding: ASCII-8BIT
# frozen_string_literal: true

require 'shellwords'

module Amx; end

# Documentation: https://aca.im/driver_docs/AMX/AMX+Acendo+Vibe.pdf

class Amx::AcendoVibe
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder
    include ::Orchestrator::Security

    descriptive_name 'AMX Acendo Vibe'
    generic_name :Mixer

    tokenize delimiter: /\r\n|\r|\n/
    tcp_port 4999

    def on_load
        on_update
    end

    def on_update
    end

    def connected
        schedule.every('20s') do
            logger.debug 'Maintaining connection..'
            battery? priority: 0
        end
    end

    def disconnected
        schedule.clear
    end

    CMDS = {
        mic_mute: '/audmic/state',
        auto_switch: '/audio/autoswitch',
        default_volume: '/audio/defvolume',
        gain: '/audio/gain/level',
        gain_mode: '/audio/gain/mode',
        source: '/audio/source',
        mute: '/audio/state',
        volume: '/audio/volume',
        battery: '/battery/state',
        bluetooth_enabled: '/bluetooth/state',
        bluetooth_status: '/bluetooth/connstate',
        camera_state: '/camera/state',
        model: '/system/model',
        system_name: '/system/name',
        version: '/system/version',
        usb_status: '/usbup/status',
        occupancy_sensitivity: 'occupancy/sensitivity',
        occupancy: '/occupancy/internal/state'
    }

    CMDS.each do |name, cmd|
        define_method "#{name}?" do |**options|
            get(cmd, **options)
        end
    end

    def mic_mute(muted = true)
        state = is_affirmative?(muted) ? 'muted' : 'normal'
        set CMDS[:mic_mute], state
    end

    def mic_unmute
        mic_mute false
    end

    def mutes(ids:, muted: true, **_)
        mute(ids, muted)
    end

    def mute(id, muted = true)
        state = is_affirmative?(muted) ? 'muted' : 'normal'
        if id == 'mic'
            mic_mute(muted)
        else
            set CMDS[:mute], state
        end
    end

    def unmute
        mute false
    end

    def auto_switch(enable)
        state = is_affirmative?(enable) ? 'on' : 'off'
        set CMDS[:auto_switch], state
    end

    def default_volume(level)
        level = in_range(level.to_i, 100)
        set CMDS[:default_volume], level
    end

    def gain(level)
        level = in_range(level.to_i, 100)
        set CMDS[:gain], level
    end

    def gain_mode(fixed)
        state = is_affirmative?(fixed) ? 'fixed' : 'var'
        set CMDS[:gain_mode], state
    end

    # aux, bluetooth, hdmi, optical or usb
    def source(input)
        set CMDS[:source], input
    end

    def fader(id, level)
        volume(level) if id != 'mic'
    end

    def volume(level)
        level = in_range(level.to_i, 100)
        set CMDS[:volume], level
    end

    def bluetooth_enabled(state)
        state = is_affirmative?(state) ? 'on' : 'off'
        set CMDS[:bluetooth_enabled], state
    end

    def pair
        exec '/bluetooth/pairing', 'pair'
    end

    def unpair
        exec '/bluetooth/pairing', 'unpair'
    end

    def system_name(name)
        set CMDS[:system_name], name
    end

    protect_method :firmware_update, :bluetooth_update, :reboot

    def firmware_update
        exec '/system/firmware/update'
    end

    def bluetooth_update
        exec '/system/firmware/update/bt'
    end

    def reboot
        exec '/system/reboot'
    end

    # AVC-5100 Only:

    def display(state)
        state = is_affirmative?(state) ? 'on' : 'off'
        set '/display/state', state
    end

    def occupancy_sensitivity(setting)
        # Valid values: off, low, medium or high
        set CMDS[:occupancy_sensitivity], setting
    end

    def ring_led_colour(red, green, blue)
        # 0..255
        set '/ringleds/color', "#{red}:#{green}:#{blue}"
    end

    def ring_led(state)
        # state = off, on or pulsing
        set '/ringleds/state', state
    end

    def received(response, resolve, command)
        logger.debug { "Soundbar sent #{response}" }

        data = response.downcase.shellsplit

        # Process events
        if data[0] == 'event'
            case data[1]
            when 'mic_mute'
                self[:mic_mute] = true
            when 'mic_unmute'
                self[:mic_mute] = false
            when 'spkr_mute'
                self[:mute] = true
            when 'spkr_unmute'
                self[:mute] = false
            when 'src_change_audio'
                self[:source] = data[2].to_sym
            when 'vol_change'
                self[:volume] = data[2].to_i
            when 'usb_conn'
                self[:usb_connected] = true
            when 'usb_dis'
                self[:usb_connected] = false
            when 'hdmi_conn'
                self[:hdmi_connected] = true
            when 'hdmi_dis'
                self[:hdmi_connected] = false
            when 'vacancy_det'
                self[:presence_detected] = false
            when 'occupancy_det'
                self[:presence_detected] = true
            end
            return :ignore
        end

        # Remove the @
        type = data[0][1..-1]

        # Check for errors
        if type == 'unsupported'
            logger.warn response
            return :abort
        end

        if type == 'error'
            logger.error "Error #{data[-1]} for command: #{data[1..-2].join(' ')}"
            return :abort
        end

        # Process responses
        path = data[1].split('/')
        arg = data[-1]

        # ignore echos
        return unless data.length > 2

        case path[1]
        when 'audmic'
            self[:mic_mute] = self[:fadermic_mute] = arg == 'muted'
        when 'audio'
            case path[2]
            when 'autoswitch'
                self[:auto_switch] = arg == 'on'
            when 'defvolume'
                self[:default_volume] = arg.to_i
            when 'gain'
                if path[3] == 'level'
                    self[:gain] = arg.to_i
                else
                    self[:gain_mode] = arg
                end
            when 'source'
                self[:source] = arg.to_sym
            when 'state'
                self[:muted] = self[:faderoutput_mute] = arg == 'muted'
            when 'volume'
                self[:volume] = self[:faderoutput] = arg.to_i
            end
        when 'battery'
            self[:battery] = arg
        when 'bluetooth'
            if path[2] == 'connstate'
                self[:bluetooth] = arg
            else
                self[:bluetooth_enabled] = arg == 'on'
            end
        when 'camera'
            self[:camera] = arg
        when 'system'
            self[path[2]] = arg
        when 'usbup'
            self[:usb_status] = (arg == 'connected')
        end

        :success
    end

    protected

    def get(path, **options)
        cmd = ['get', path].shelljoin
        logger.debug { "sending: #{cmd}" }
        send "#{cmd}\r", options
    end

    def set(path, *args, **options)
        cmd = ['set', path, *args].shelljoin
        logger.debug { "sending: #{cmd}" }
        send "#{cmd}\r", options
    end

    def exec(path, *args, **options)
        cmd = ['exec', path, *args].shelljoin
        logger.debug { "sending: #{cmd}" }
        send "#{cmd}\r", options
    end
end
