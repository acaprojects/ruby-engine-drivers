# encoding: ASCII-8BIT
# frozen_string_literal: true

module Helvar; end

# Documentation: https://aca.im/driver_docs/Helvar/HelvarNet-Overview.pdf

class Helvar::Net
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder

    # Discovery Information
    tcp_port 50000
    descriptive_name 'Helvar Net Lighting Gateway'
    generic_name :Lighting

    # Communication settings
    tokenize delimiter: '#'
    default_settings version: 2

    def on_load
        on_update
    end

    def on_unload; end

    def on_update
        @version = setting(:version)
    end

    def connected
        schedule.every('40s') do
            logger.debug '-- Polling Helvar'
            query_software_version
        end
    end

    def disconnected
        schedule.clear
    end

    def lighting(group, state)
        level = is_affirmative?(state) ? 100 : 0
        light_level(group, level)
    end

    def light_level(group, level, fade = 1000)
        fade = (fade / 10).to_i
        self[:"area#{group}_level"] = level
        group_level(group: group, level: level, fade: fade, name: "group_level#{group}")
    end

    def trigger(group, scene, fade = 1000)
        fade = (fade / 10).to_i
        self[:"area#{group}"] = scene
        group_scene(group: group, scene: scene, fade: fade, name: "group_scene#{group}")
    end

    def get_current_preset(group)
        query_last_scene(group: group)
    end

    Commands = {
        '11' => :group_scene,
        '12' => :device_scene,
        '13' => :group_level,
        '14' => :device_level,
        '15' => :group_proportion,
        '16' => :device_proportion,
        '17' => :group_modify_proportion,
        '18' => :device_modify_proportion,
        '19' => :group_emergency_test,
        '20' => :device_emergency_test,
        '21' => :group_emergency_duration_test,
        '22' => :device_emergency_duration_test,
        '23' => :group_emergency_stop,
        '24' => :device_emergency_stop,

        # Query commands
        '70' => :query_lamp_hours,
        '71' => :query_ballast_hours,
        '72' => :query_max_voltage,
        '73' => :query_min_voltage,
        '74' => :query_max_temp,
        '75' => :query_min_temp,
        '100' => :query_device_types_with_addresses,
        '101' => :query_clusters,
        '102' => :query_routers,
        '103' => :query_LSIB,
        '104' => :query_device_type,
        '105' => :query_description_group,
        '106' => :query_description_device,
        '107' => :query_workgroup_name, # must use UDP
        '108' => :query_workgroup_membership,
        '109' => :query_last_scene,
        '110' => :query_device_state,
        '111' => :query_device_disabled,
        '112' => :query_lamp_failure,
        '113' => :query_device_faulty,
        '114' => :query_missing,
        '129' => :query_emergency_battery_failure,
        '150' => :query_measurement,
        '151' => :query_inputs,
        '152' => :query_load,
        '160' => :query_power_consumption,
        '161' => :query_group_power_consumption,
        '164' => :query_group,
        '165' => :query_groups,
        '166' => :query_scene_names,
        '167' => :query_scene_info,
        '170' => :query_emergency_func_test_time,
        '171' => :query_emergency_func_test_state,
        '172' => :query_emergency_duration_time,
        '173' => :query_emergency_duration_state,
        '174' => :query_emergency_battery_charge,
        '175' => :query_emergency_battery_time,
        '176' => :query_emergency_total_lamp_time,
        '185' => :query_time,
        '186' => :query_longitude,
        '187' => :query_latitude,
        '188' => :query_time_zone,
        '189' => :query_daylight_savings,
        '190' => :query_software_version,
        '191' => :query_helvar_net
    }
    Commands.merge!(Commands.invert)
    Commands.each do |name, cmd|
        next unless name.is_a?(Symbol)
        define_method name do |**options|
            do_send(cmd, **options)
        end
    end

    Params = {
        'V' => :ver,
        'Q' => :seq,
        'C' => :cmd,
        'A' => :ack,
        '@' => :addr,
        'F' => :fade,
        'T' => :time,
        'L' => :level,
        'G' => :group,
        'S' => :scene,
        'B' => :block,
        'N' => :latitude,
        'E' => :longitude,
        'Z' => :time_zone,
        # brighter or dimmer than the current level by a % of the difference
        'P' => :proportion,
        'D' => :display_screen,
        'Y' => :daylight_savings,
        'O' => :force_store_scene,
        'K' => :constant_light_scene
    }

    def received(data, resolve, command)
        logger.debug { "Helvar sent #{data}" }

        # remove connectors from multi-part responses
        data.delete!('$')

        indicator = data[0]
        case indicator
        when '?', '>'
            data, value = data.split('=')
            params = {}
            data.split(',').each do |param|
                parts = param.split(':')
                if parts.length > 1
                    params[Params[parts[0]]] = parts[1]
                elsif parts[0][0] == '@'
                    params[:addr] == parts[0][1..-1]
                else
                    logger.debug { "unknown param type #{param}" }
                end
            end

            # Check for :ack
            ack = params[:ack]
            if ack
                return :abort if ack != '1'
                return :success
            end

            cmd = Commands[params[:cmd]]
            case cmd
            when :query_last_scene
                blk = params[:block]
                if blk
                    self[:"area#{params[:group]}_block#{blk}"] = value.to_i
                else
                    self[:"area#{params[:group]}"] = value.to_i
                end
            else
                logger.debug { "unknown response value\n#{cmd} = #{value}" }
            end
        when '!'
            error = Errors[data.split('=')[1]]
            self[:last_error] = "error #{error} for #{data}"
            logger.warn self[:last_error]
            return :abort
        else
            logger.info "unknown request #{data}"
        end

        :success
    end


    protected


    Errors = {
        '0' => 'success',
        '1' => 'Invalid group index parameter',
        '2' => 'Invalid cluster parameter',
        '3' => 'Invalid router',
        '4' => 'Invalid router subnet',
        '5' => 'Invalid device parameter',
        '6' => 'Invalid sub device parameter',
        '7' => 'Invalid block parameter',
        '8' => 'Invalid scene',
        '9' => 'Cluster does not exist',
        '10' => 'Router does not exist',
        '11' => 'Device does not exist',
        '12' => 'Property does not exist',
        '13' => 'Invalid RAW message size',
        '14' => 'Invalid messages type',
        '15' => 'Invalid message command',
        '16' => 'Missing ASCII terminator',
        '17' => 'Missing ASCII parameter',
        '18' => 'Incompatible version'
    }

    def do_send(cmd, ver: @version, group: nil, block: nil, level: nil, scene: nil, fade: nil, addr: nil, **options)
        req = String.new(">V:#{ver},C:#{cmd}")
        req << ",G:#{group}" if group
        req << ",B:#{block}" if block
        req << ",L:#{level}" if level
        req << ",S:#{scene}" if scene
        req << ",F:#{fade}"  if fade
        req << ",@:#{addr}"  if addr
        req << '#'
        logger.debug { "Requesting helvar: #{req}" }
        send(req, options)
    end
end
