module Clipsal; end


#
# Common Headers
#     0x03 == point - point -multipoint, low pri
#     0x05 == point - multipoint, low pri
#     0x06 == point - point, low pri
#
#     11xxx110  (x == reserved)
#     -- Priority, 11 == high, 00 == low
#          --- Destination, 011 = P-P-M, 101 = P-M, 110 = P-P
#
#
# Commands are formatted as: \ + Header + 00 + Data + checksum + <cr>
#
# Turn group on \ + 05 (MP header) + 38 (lighting) + 00 + 79 (group on) + XX (group number) + checksum + <cr>
# Turn group off \ + 05 (MP header) + 38 (lighting) + 00 + 01 (group off) + XX (group number) + checksum + <cr>
# Ramp a group \ + 05 (MP header) + 38 (lighting) + 00 + 79 (group on) + XX (group number) + checksum + <cr>
#



class Clipsal::CBus
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder

    # Discovery Information
    tcp_port 10001
    descriptive_name 'Clipsal CBus Lighting Gateway'
    generic_name :Lighting

    # Communication settings
    tokenize delimiter: "\x0D"
    wait_response false
    delay between_sends: 100

    def on_load
    end

    def on_unload
    end

    def on_update
    end


    def connected
        send("|||\r", priority: 99)    # Ensure we are in smart mode
        @polling_timer = schedule.every('60s') do
            logger.debug "-- Polling CBUS"
            send("|||\r", priority: 0)    # Ensure we are in smart mode
        end
    end

    def disconnected
        @polling_timer.cancel unless @polling_timer.nil?
        @polling_timer = nil
    end


    def lighting(group, state, application = 0x38)
        group = group & 0xFF
        application = application & 0xFF

        command = [0x05, application, 0x00]
        if is_affirmative? state
            state = On
            command << 0x79 # Group on
        else
            state = Off
            command << 0x01 # Group off
        end
        command << group

        self["lighting_group_#{group}"] = state

        do_send(command)
    end


    # Allows custom feedback for non-lighting devices connected to CBus
    def toggle_group(application, group, state = nil, feedback = nil)
        lighting(group, true, application)
        schedule.in('1s') do
            lighting(group, false, application)
            stat = feedback ? feedback.to_s.to_sym : :"toggle_group_#{group}"

            self[stat] = state.nil? ? true : state
        end
    end


    def light_level(group, level, application = 0x38, rate = 0b0001)

        #
        # rates:
        # => 0 == instant
        # => 1 == 4sec
        # => 2 == 8sec etc
        #
        rate = ((rate & 0x0F) << 3) | 0b010    # The command is structured as: 0b0 xxxx 010 where xxxx == rate
        group = group & 0xFF
        level = level & 0xFF
        application = application & 0xFF

        stop_fading(group)
        command = [0x05, application, 0x00, rate, group, level]

        do_send(command)
    end

    def stop_fading(group)
        command = [0x05, 0x38, 0x00, 0x09, group]
        do_send(command)
    end



    def blinds(application, group, action)
        group = group & 0xFF
        application = application & 0xFF

        command = [0x05, application, 0x00]
        if is_affirmative?(action)
            action = Down
            command += [0x1A, group, 0x00]
            self["blinds_group_#{group}"] = Down
        else
            command += [0x02, group]

            if is_negatory?(action)
                action = Up
                command << 0xFF
                self["blinds_group_#{group}"] = Up
            else
                # Stop
                command << 5
                self["blinds_group_#{group}"] = :stopped
            end
        end

        do_send(command)
    end


    def trigger(group, action)
        group = group.to_i & 0xFF
        action = action.to_i & 0xFF
        command = [0x05, 0xCA, 0x00, 0x02, group, action]

        self["trigger_group_#{group}"] = action

        do_send(command)
    end


    def trigger_kill(group)
        group = group.to_i

        group = group & 0xFF
        command = [0x05, 0xCA, 0x00, 0x01, group]
        do_send(command)
    end


    def received(data, resolve, command)
        # Debug here will sometimes have the \n char
        # This is removed by the hex_to_byte function
        logger.debug { "CBus sent #{data}" }

        data = str_to_array(hex_to_byte(data))

        if !check_checksum(data)
            logger.warn "CBus checksum failed"
            return :failed
        end

        # We are only looking at Point -> MultiPoint commands
        if data[0] != 0x05
            logger.debug { "was not a Point -> MultiPoint response: type 0x#{data[0].to_s(16)}" }
            return :ignore
        end
        # 0x03 == Point -> Point -> MultiPoint
        # 0x06 == Point -> Point

        application = data[2]    # The application being referenced
        commands = data[4..-2]    # Remove the header + checksum

        while commands.length > 0
            current = commands.shift

            case application
            when 0xCA            # Trigger group
                case current
                when 0x02            # Trigger Event (ex: 0504CA00 020101 29)
                    self["trigger_group_#{commands.shift}"] = commands.shift    # Action selector
                when 0x01            # Trigger Min
                    self["trigger_group_#{commands.shift}"] = 0
                when 0x79            # Trigger Max
                    self["trigger_group_#{commands.shift}"] = 0xFF
                when 0x09            # Indicator Kill (ex: 0504CA00 0901 23)
                    logger.debug { "trigger kill request: grp 0x#{commands[0].to_s(16)}" }
                    commands.shift        # Group (turns off indicators of all scenes triggered by this group)
                else
                    logger.debug { "unknown trigger group request 0x#{current.to_s(16)}" }
                    break    # We don't know what data is here
                end
            when 0x30..0x5F        # Lighting group
                case current
                when 0x01            # Group off (ex: 05043800 0101 0102 0103 0104 7905 33)
                    self["lighting_group_#{commands.shift}"] = Off
                when 0x79            # Group on (ex: 05013800 7905 44)
                    self["lighting_group_#{commands.shift}"] = On
                when 0x02 # Blinds up or stop
                    # Example: 05083000022FFF93
                    group = commands.shift
                    value = commands.shift
                    if value == 0xFF
                        self["blinds_group_#{group}"] = Up
                    elsif value == 5
                        self["blinds_group_#{group}"] = :stopped
                    end
                when 0x1A # Blinds down
                    # Example: 050830001A2F007A
                    group = commands.shift
                    value = commands.shift
                    self["blinds_group_#{group}"] = Down if value == 0x00
                when 0x09            # Terminate Ramp
                    logger.debug { "terminate ramp request: grp 0x#{commands[0].to_s(16)}" }
                    commands.shift        # Group address
                else
                    # Ramp to level (ex: 05013800 0205FF BC)
                    #                    Header   cmd    cksum
                    if ((current & 0b10000101) == 0) && commands.length > 1
                        logger.debug { "ramp request: grp 0x#{commands[0].to_s(16)} - level 0x#{commands[1].to_s(16)}" }
                        commands.shift(2)    # Group address, level
                    else
                        logger.debug { "unknown lighting request 0x#{current.to_s(16)}" }
                        break    # We don't know what data is here
                    end
                end
            else
                logger.debug { "unknown application request app 0x#{application.to_s(16)}" }
                break    # We haven't programmed this application
            end
        end

        return :success
    end


    protected


    def checksum(data)
        check = 0
        data.each do |byte|
            check += byte
        end
        check = check % 0x100
        check = ((check ^ 0xFF) + 1) & 0xFF
        return check
    end

    def check_checksum(data)
        check = 0
        data.each do |byte|
            check += byte
        end
        return (check % 0x100) == 0x00
    end


    def do_send(command, options = {})
        string = byte_to_hex(command << checksum(command)).upcase
        logger.debug { "Requesting CBus: #{string}" }
        send("\\#{string}\r", options)
    end
end
