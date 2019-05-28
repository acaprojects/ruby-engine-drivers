# encoding: ASCII-8BIT
# frozen_string_literal: true

module Qsc; end

# Documentation: https://aca.im/driver_docs/QSC/QRCDocumentation.pdf

class Qsc::QSysRemote
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder


    # Discovery Information
    tcp_port 1710
    descriptive_name 'QSC Audio DSP'
    generic_name :Mixer

    # Communication settings
    # Wait for null terminator before processing command
    tokenize delimiter: "\0"


    JsonRpcVer = '2.0'
    Errors = {
        -32700 => 'Parse error. Invalid JSON was received by the server.',
        -32600 => 'Invalid request. The JSON sent is not a valid Request object.',
        -32601 => 'Method not found.',
        -32602 => 'Invalid params.',
        -32603 => 'Server error.',

        2 => 'Invalid Page Request ID',
        3 => 'Bad Page Request - could not create the requested Page Request',
        4 => 'Missing file',
        5 => 'Change Groups exhausted',
        6 => 'Unknown change croup',
        7 => 'Unknown component name',
        8 => 'Unknown control',
        9 => 'Illegal mixer channel index',
        10 => 'Logon required'
    }


    def on_load
        on_update
    end

    def on_update
        @db_based_faders = setting(:db_based_faders)
        @integer_faders = setting(:integer_faders)
    end

    def connected
        schedule.every('20s') do
            logger.debug "Maintaining Connection"
            no_op
        end

        @id = 0

        logon
    end

    def disconnected
        #
        # Disconnected may be called without calling connected
        #    Hence the check if timer is nil here
        #
        schedule.clear
    end


    def no_op
        do_send(cmd: :NoOp, priority: 0)
    end

    def get_status
        do_send(next_id, cmd: :StatusGet, params: 0, priority: 0)
    end

    def logon(username = setting(:username), password = setting(:password))
        # Don't login if there is no username or password set
        return unless username

        do_send(cmd: :Logon, params: {
            :User =>  username,
            :Password => password
        }, priority: 99)
    end


    # ----------------
    # CONTROL CONTROLS
    # ----------------
    def control_set(name, value, ramp = nil, **options)
        params = {
            :Name =>  name,
            :Value => value
        }
        params[:Ramp] = ramp if ramp

        do_send(next_id, cmd: :"Control.Set", params: params, **options)
    end

    def control_get(*names, **options)
        do_send(next_id, cmd: :"Control.Get", params: names.flatten, **options)
    end


    # ------------------
    # COMPONENT CONTROLS
    # ------------------
    def component_get(name, *controls, **options)
        # Example usage:
        # component_get 'My AMP', 'ent.xfade.gain', 'ent.xfade.gain2'
        controls = controls.flatten
        controls.collect! { |ctrl| { :Name => ctrl } }

        do_send(next_id, cmd: :"Component.Get", params: {
            :Name => name,
            :Controls => controls
        }, **options)
    end

    def component_set(name, value, **options)
        # Example usage:
        # component_set 'My APM', { :Name => 'ent.xfade.gain', :Value => -100 }, {...}
        values = value.is_a?(Array) ? value : [value]
        # NOTE:: Can't use Array() helper on hashes as they are converted to arrays.

        do_send(next_id, cmd: :"Component.Set", params: {
            :Name => name,
            :Controls => values
        }, **options)
    end

    def component_trigger(component, trigger, **options)
        do_send(next_id, cmd: :"Component.Trigger", params: {
            :Name => component,
            :Controls => [{ :Name => trigger }]
        }, **options)
    end

    def get_components(**options)
        do_send(next_id, cmd: :"Component.GetComponents", **options)
    end


    # -------------
    # Change Groups
    # -------------
    def change_group_add_controls(group_id, *controls, **options)
        params = {
            :Id => group_id,
            :Controls => controls
        }

        do_send(next_id, cmd: :"ChangeGroup.AddControl", params: params, **options)
    end

    def change_group_remove_controls(group_id, *controls, **options)
        params = {
            :Id => group_id,
            :Controls => controls
        }

        do_send(next_id, cmd: :"ChangeGroup.Remove", params: params, **options)
    end

    def change_group_add_component(group_id, component_name, *controls, **options)
        controls.collect! do |ctrl|
            {
                :Name => ctrl
            }
        end

        do_send(next_id, cmd: :"ChangeGroup.AddComponentControl", params: {
            :Id => group_id,
            :Component => {
                :Name => component_name,
                :Controls => controls
            }
        }, **options)
    end

    # Returns values for all the controls
    def poll_change_group(group_id, **options)
        do_send(next_id, cmd: :"ChangeGroup.Poll", params: {:Id => group_id}, **options)
    end

    # Removes the change group
    def destroy_change_group(group_id, **options)
        do_send(next_id, cmd: :"ChangeGroup.Destroy", params: {:Id => group_id}, **options)
    end

    # Removes all controls from change group
    def clear_change_group(group_id, **options)
        do_send(next_id, cmd: :"ChangeGroup.Clear", params: {:Id => group_id}, **options)
    end

    # Where every is the number of seconds between polls
    def auto_poll_change_group(group_id, every, **options)
        params = {
            :Id => group_id,
            :Rate => every
        }
        options[:wait] = false
        do_send(next_id, cmd: :"ChangeGroup.AutoPoll", params: params, **options)
    end


    # --------------
    # MIXER CONTROLS
    # --------------
    def mixer(name, inouts, mute = false, *_,  **options)
        # Example usage:
        # mixer 'Parade', {1 => [2,3,4], 3 => 6}, true

        inouts.each do |input, outputs|
            outs = outputs.class == Array ? outputs : [outputs]

            do_send(next_id, cmd: :"Mixer.SetCrossPointMute", params: {
                :Mixer => name,
                :Inputs => input.to_s,
                :Outputs => outputs.join(' '),
                :Value => mute
            }, **options)
        end
    end

    Faders = {
        matrix_in: {
            type: :"Mixer.SetInputGain",
            pri: :Inputs
        },
        matrix_out: {
            type: :"Mixer.SetOutputGain",
            pri: :Outputs
        },
        matrix_crosspoint: {
            type: :"Mixer.SetCrossPointGain",
            pri: :Inputs,
            sec: :Outputs
        }
    }
    def matrix_fader(name, level, index, type = :matrix_out, **options)
        info = Faders[type]

        params = {
            :Mixer => name,
            :Value => level
        }

        if info[:sec]
            params[info[:pri]] = index[0]
            params[info[:sec]] = index[1]
        else
            params[info[:pri]] = index
        end

        do_send(next_id, cmd: info[:type], params: params, **options)
    end

    # Named params version
    def matrix_faders(ids:, level:, index:, type: :matrix_out, **options)
        fader(ids, level, index, type, **options)
    end


    Mutes = {
        matrix_in: {
            type: :"Mixer.SetInputMute",
            pri: :Inputs
        },
        matrix_out: {
            type: :"Mixer.SetOutputMute",
            pri: :Outputs
        }
    }
    def matrix_mute(name, value, index, type = :matrix_out, **options)
        info = Mutes[type]

        params = {
            :Mixer => name,
            :Value => value
        }

        if info[:sec]
            params[info[:pri]] = index[0]
            params[info[:sec]] = index[1]
        else
            params[info[:pri]] = index
        end

        do_send(next_id, cmd: info[:type], params: params, **options)
    end

    # Named params version
    def matrix_mutes(ids:, muted: true, index:, type: :matrix_out, **options)
        mute(ids, muted, index, type, **options)
    end


    # ---------------------
    # COMPATIBILITY METHODS
    # ---------------------

    def fader(fader_id, level, component = nil, type = :fader, use_value: false)
        faders = Array(fader_id)
        if component
            if @db_based_faders || use_value
                level = level.to_f / 10.0 if @integer_faders && !use_value
                fads = faders.map { |fad| {Name: fad, Value: level} }
            else
                level = level.to_f / 1000.0 if @integer_faders
                fads = faders.map { |fad| {Name: fad, Position: level} }
            end
            component_set(component, fads, name: "level_#{faders[0]}").then do
                component_get(component, faders)
            end
        else
            reqs = faders.collect { |fad| control_set(fad, level) }
            reqs.last.then { control_get(faders) }
        end
    end

    def faders(ids:, level:, index: nil, type: :fader, **_)
        fader(ids, level, index, type)
    end

    def mute(fader_id, value = true, component = nil, type = :fader)
        val = is_affirmative?(value)
        fader(fader_id, val, component, type, use_value: true)
    end

    def mutes(ids:, muted: true, index: nil, type: :fader, **_)
        mute(ids, muted, index, type)
    end

    def unmute(fader_id, component = nil, type = :fader)
        mute(fader_id, false, component, type)
    end

    def query_fader(fader_id, component = nil, type = :fader)
        faders = Array(fader_id)

        if component
            component_get(component, faders)
        else
            control_get(faders)
        end
    end

    def query_faders(ids:, index: nil, type: :fader, **_)
        query_fader(ids, component, type)
    end

    def query_mute(fader_id, component = nil, type = :fader)
        query_fader(fader_id, component, type)
    end

    def query_mutes(ids:, index: nil, type: :fader, **_)
        query_fader(ids, component, type)
    end


    # -------------------
    # RESPONSE PROCESSING
    # -------------------
    DECODE_OPTIONS = {
        symbolize_names: true
    }.freeze

    def received(data, resolve, command)
        logger.debug { "QSys sent: #{data}" }

        response = JSON.parse(data, DECODE_OPTIONS)
        logger.debug { JSON.pretty_generate(response) }

        err = response[:error]
        if err
            logger.warn "Error code #{err[:code]} - #{Errors[err[:code]]}\n#{err[:message]}"
            return :abort
        end

        result = response[:result]
        case result
        when Hash
            controls = result[:Controls]

            if controls
                # Probably Component.Get
                process(controls, name: result[:Name])
            elsif result[:Platform]
                # StatusGet
                self[:platform] = result[:Platform]
                self[:state] = result[:State]
                self[:design_name] = result[:DesignName]
                self[:design_code] = result[:DesignCode]
                self[:is_redundant] = result[:IsRedundant]
                self[:is_emulator] = result[:IsEmulator]
                self[:status] = result[:Status]
            end
        when Array
            # Control.Get
            process(result)
        end

        return :success
    end


    protected


    BoolVals = ['true', 'false']
    def process(values, name: nil)
        component = name.present? ? "_#{name}" : ''
        values.each do |value|
            name = value[:Name]
            val = value[:Value]

            next unless val

            pos = value[:Position]
            str = value[:String]

            if BoolVals.include?(str)
                self["fader#{name}#{component}_mute"] = str == 'true'
            else
                # Seems like string values can be independant of the other values
                # This should mostly work to detect a string value
                if val == 0.0 && pos == 0.0 && str[0] != '0'
                    self["#{name}#{component}"] = str
                    next
                end

                if pos
                    # Float between 0 and 1
                    if @integer_faders
                        self["fader#{name}#{component}"] = (pos * 1000).to_i
                    else
                        self["fader#{name}#{component}"] = pos
                    end
                elsif val.is_a?(String)
                    self["#{name}#{component}"] = val
                else
                    if @integer_faders
                        self["fader#{name}#{component}"] = (val * 10).to_i
                    else
                        self["fader#{name}#{component}"] = val
                    end
                end
            end
        end
    end

    def next_id
        @id += 1
        @id
    end

    def do_send(id = nil, cmd:, params: {}, **options)
        # Build the request
        req = {
            jsonrpc: JsonRpcVer,
            method: cmd,
            params: params
        }
        req[:id] = id if id

        logger.debug { "requesting: #{req}" }

        # Append the null terminator
        cmd = req.to_json
        cmd << "\0"

        # send the command
        send(cmd, options)
    end
end
