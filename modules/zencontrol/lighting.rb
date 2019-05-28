# encoding: ASCII-8BIT
# frozen_string_literal: true

module Zencontrol; end

# Documentation: https://aca.im/driver_docs/zencontrol/lighting_udp.pdf

class Zencontrol::Lighting
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder

    # Discovery Information
    udp_port 5108
    descriptive_name 'Zencontrol Lighting'
    generic_name :Lighting

    # Communication settings
    wait_response false

    def on_load
        on_update
    end

    def on_update
        @version = setting(:version) || 1
        controller = setting(:controller_id)&.to_i

        if controller
            @controller = int_to_array(controller, bytes: 6)
        else
            @controller = [0xFF] * 6
        end
    end

    # Using indirect commands
    def trigger(area, scene)
        # Area 128 – 191 == Address 0 – 63
        # Area 192 – 207 == Group 0 – 15
        # Area 255 == Broadcast
        #
        # Scene 0 - 15
        area = in_range(area.to_i, 127) + 128
        scene = in_range(scene.to_i, 15) + 16
        do_send(area, scene)
    end

    # Using direct command
    def light_level(area, level, channel = nil, fade = nil)
        area = in_range(area.to_i, 127)
        level = in_range(level.to_i, 255)
        do_send(area, level.to_i)
    end

    def received(data, resolve, command)
        logger.debug { "received 0x#{byte_to_hex(data)}" }
        :success
    end


    protected


    def do_send(address, command, **options)
        cmd = [@version, *@controller, address, command]
        send(cmd, options)
    end
end
