load File.expand_path('./sx_telnet.rb', File.dirname(__FILE__))


class Cisco::TelePresence::SxSeries
    # Discovery Information
    descriptive_name 'Cisco TelePresence'
    generic_name :VidConf


    def on_load
        super
    end
    
    def on_update
    end
    
    def connected
        super

        call_status
        @polling_timer = schedule.every('58s') do
            logger.debug "-- Polling Cisco SX"
            call_status
        end
    end
    
    def disconnected
        super

        @polling_timer.cancel unless @polling_timer.nil?
        @polling_timer = nil
    end



    # ================
    # Common functions
    # ================

    def show_camera_pip(value)
        feedback = is_affirmative?(value)
        val = feedback ? 'On' : 'Off'

        command('CamCtrlPip', params({
            :Mode => val
        }), name: :camera_pip).then do
            self[:camera_pip] = feedback
        end
    end

    def toggle_camera_pip
        show_camera_pip !self[:camera_pip]
    end

    CallCommands ||= Set.new([:accept, :reject, :disconnect, :hold, :join, :resume, :ignore])
    def call(cmd, call_id = nil, **options)
        name = cmd.downcase.to_sym

        command(:call, cmd, params({
            :CallId => call_id
        }), name: name).then do
            call_status
        end
    end

    def call_status
        status(:call, max_waits: 100)
    end

    SearchDefaults = {
        :PhonebookType => :Corporate,
        :Limit => 10,
        :ContactType => :Contact,
        :SearchField => :Name
    }
    def search(text, opts = {})
        opts = SearchDefaults.merge(opts)
        opts[:SearchString] = text
        command(:phonebook, :search, params(opts), name: :phonebook, max_waits: 100)
    end


    # ====================
    # END Common functions
    # ====================


    def audio(*args, **options)
        command :audio, *args, params(options)
    end

    def history(cmd, options = {})
        command :CallHistroy, cmd, params(options)
    end


    # Options include: Protocol, CallRate, CallType, DisplayName, Appearance
    def dial(number, options = {})
        options[:Number] = number
        command :dial, params(options)
    end

    # left, right, up, down, zoomin, zoomout
    def far_end_camera(action, call_id = @last_call_id)
        req = action.downcase.to_sym
        if req == :stop
            command :FarEndControl, :Camera, :Stop, "CallId:#{call_id}"
        else
            command :FarEndControl, :Camera, :Move, "CallId:#{call_id} Value:#{req}"
        end
    end

    # Source is a number from 0..15
    def far_end_source(source, call_id = @last_call_id)
        command :FarEndControl, :Source, :Select, "CallId:#{call_id} SourceId:#{source}"
    end



    # Also supports stop
    def presentation(action = :start)

    end

    def save_preset(name)

    end

    def preset(name)

    end

    # pip / 
    def video

    end

    
    
    ResponseType = {
        '**' => :complete
        '*r' => :call
    }
    def received(data, resolve, command)
        logger.debug { "Tele sent #{data}" }

        result = Shellwords.split data
        response = ResponseType[result[0]]

        if command
            if response == :complete
                # Update status variables
                if @listing_phonebook
                    @listing_phonebook = false

                    # expose results
                    self[:search_results] = @results
                elsif @call_status
                    @call_status[:id] = @last_call_id
                    self[:call_status] = @call_status
                    @call_status = nil
                end
                return :success
            elsif response.nil?
                return :ignore
            end
        end

        return case response
        when :call
            process_call result
        else
            :success
        end
    end


    protected


    def process_call(result)
        type = result[1].downcase.to_sym

        case type
        when :phonebooksearchresult
            @listing_phonebook = true

            if result[3] == 'Contact'
                contact = @results[result[4].to_i - 1]
                if contact.nil?
                    contact = {
                        methods: []
                    }
                    @results << contact
                end

                if result[5] == 'ContactMethod'
                    method = contact[:methods][result[6].to_i - 1]
                    if method.nil?
                        method = {}
                        contact[:methods] << method
                    end

                    entry = result[7].chop
                    method[entry.downcase.to_sym] = result[8]
                else
                    entry = result[5].chop
                    contact[entry.downcase.to_sym] = result[6]
                end
            else # ResultInfo
                self[:results_total] = result[5].to_i
                @results = []
            end
        when :call
            @call_status ||= {}
            @last_call_id = result[2].to_i

            # NOTE: this will fail for "Encryption Type:"
            # however I don't think we'll ever really need to display this
            entry = result[3].chop
            @call_status[entry.downcase.to_sym] = result[4]
        end

        :ignore
    end
end

