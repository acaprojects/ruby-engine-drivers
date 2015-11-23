module Qsc; end

class Qsc::QSys
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder


    # Discovery Information
    tcp_port 1710
    descriptive_name 'QSC Audio DSP'
    generic_name :Mixer

    # Communication settings
    # Wait for null terminator before processing command
    tokenize delimiter: "\0"


    JsonRpcVer = '2.0'.freeze
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
    end

    def connected
        @polling_timer = schedule.every('1m') do
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
        @polling_timer.cancel unless @polling_timer.nil?
        @polling_timer = nil
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
        do_send(next_id, cmd: :"Control.Get", params: names, **options)
    end


    # ------------------
    # COMPONENT CONTROLS
    # ------------------
    def component_get(name, *controls, **options)
        # Example usage:
        # component_get 'My APM', 'ent.xfade.gain', 'ent.xfade.gain2'

        controls.collect! do |ctrl|
            {
                :Name => ctrl
            }
        end

        do_send(next_id, cmd: :"Component.Get", params: {
            :Name => name,
            :Controls => controls
        }, **options)
    end

    def component_set(name, *values, **options)
        # Example usage:
        # component_set 'My APM', { :Name => 'ent.xfade.gain', :Value => -100 }, {...}

        do_send(next_id, cmd: :"Component.Set", params: {
            :Name => name,
            :Controls => values
        }, **options)
    end

    def get_components(**options)
        do_send(next_id, cmd: :"Component.GetComponents", **options)
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
    def fader(name, level, index, type = :matrix_out, **options)
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
    def faders(ids:, level:, index:, type: :matrix_out, **options)
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
    def mute(name, value, index, type = :matrix_out, **options)
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
    def mutes(ids:, muted: true, index:, type: :matrix_out, **options)
        mute(ids, muted, index, type, **options)
    end



    # -------------------
    # RESPONSE PROCESSING
    # -------------------
    def received(data, resolve, command)
        logger.debug { "QSys sent: #{data}" }

        response = JSON.parse(data)
        logger.debug { JSON.pretty_generate(response) }

        return :success
    end


    protected
    

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

        # Append the null terminator
        cmd = req.to_json
        cmd << "\0"

        # send the command
        send(cmd, options)
    end
end
