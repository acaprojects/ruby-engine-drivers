
module Cisco::TelePresence::SxSeriesCommon
    def on_load
        super

        self[:presentation] = :none
        on_update
    end

    def on_update
        @corporate_dir = setting(:use_corporate_directory) || false
        @default_source = setting(:presentation) || 3
        @count = 0

        @dir_sync&.cancel
        @dir_sync = schedule.cron("0 5 * * *") { extract_phonebook }

        extract_phonebook if self[:connected] && !self[:complete_phonebook].present?
    end

    def connected
        super

        # Configure in some sane defaults
        do_send 'xConfiguration Standby Control: Off'
        call_status
        pip_mode?
        schedule.every('5s') do
            logger.debug "-- Polling Cisco SX"
            call_status
            video_output_mode?

            if @count <= 0
                mute_status
                @count = 12
            else
                @count -= 1
            end
        end

        schedule.every('60s') { booking_list }
    end

    def disconnected
        super

        @listing_phonebook = false
        @listing_bookings = false
        schedule.clear
    end



    # ================
    # Common functions
    # ================

    def show_camera_pip(value)
        feedback = is_affirmative?(value)
        val = feedback ? 'On' : 'Off'

        command('Video Selfview Set', params({
            :Mode => val
        }), name: :camera_pip).then do
            self[:camera_pip] = feedback
        end
    end

    def toggle_camera_pip
        show_camera_pip !self[:camera_pip]
    end

    def pip_mode?
        status 'Video Selfview Mode'
    end


    # Options include: Protocol, CallRate, CallType, DisplayName, Appearance
    def dial(number, options = {})
        options[:Number] = number

        command(:dial, params(options), name: :dial, delay: 500).then do
            call_status
        end
    end

    CallCommands ||= Set.new([:accept, :reject, :disconnect, :hold, :join, :resume, :ignore, :dtmfsend])
    def call(cmd, call_id = @last_call_id, **options)
        name = cmd.to_s.downcase.to_sym

        command(:call, cmd, params({
            :CallId => call_id
        }.merge(options)), name: name, delay: 500).then do
            call_status
        end
    end

    def call_status
        status(:call, name: :call)
    end

    def mute(mute = true)
        if mute
            audio :microphones, :mute
            self[:mute] = true
        else
            unmute
        end
    end

    def unmute
        audio :microphones, :unmute
        self[:mute] = false
    end

    def mute_status
        status(:audio, :microphones, :mute)
    end

    SearchDefaults = {
        :PhonebookType => :Local,
        :Limit => 10,
        :ContactType => :Contact,
        :SearchField => :Name
    }
    def search(text, opts = {}, **options)
        opts[:PhonebookType] ||= 'Corporate' if @corporate_dir
        opts = SearchDefaults.merge(opts)
        opts[:SearchString] = text if text
        command(:phonebook, :search, params(opts), **{name: :phonebook, max_waits: 100}.merge(options))
    end

    def clear_search_results
        self[:search_results] = []
    end

    def extract_phonebook
        # [{
        #     type: "folder",
        #     id: "c_12",
        #     name: "Name of the Folder",
        #     contents: []
        # }, ...]
        @complete_phonebook = []
        @current_folder = @complete_phonebook
        @folder_queue = []

        search(nil, {
          ContactType: "Any",
          Limit: 1000
        }, name: :extract, max_waits: 10000).then do
            loop do
                @results.each do |entry|
                  @current_folder << entry
                  @folder_queue << entry if entry[:folder_id]
                end
                break if @folder_queue.empty?

                folder = @folder_queue.shift
                @current_folder = folder[:contents]

                begin
                    search(nil, {
                      ContactType: "Any",
                      FolderId: folder[:folder_id],
                      Limit: 1000
                    }, name: :extract, max_waits: 10000).value
                rescue => error
                    logger.print_error error, 'extracting phonebook data'
                end
            end

            self[:complete_phonebook] = @complete_phonebook
        end
    end

    # Options include: auto, custom, equal, fullscreen, overlay, presentationlargespeaker, presentationsmallspeaker, prominent, single, speaker_full
    def layout(mode, target = :local)
        self[:"layout_#{target}"] = mode

        # Older version of API (pre 2016): command(:Video, :PictureLayoutSet, params({
        command(:Video, :Layout, :LayoutFamily, :Set, params({
            :Target => target,
            :LayoutFamily => mode
        }), name: :layout)
    end


    def send_DTMF(string, call_id = @last_call_id)
        call(:DTMFSend, call_id, :DTMFString => string)
        command(:DTMFSend, params({
            :CallId => call_id,
            :DTMFString => string
        }))
    end

    def speaker_track(enabled)
        value = enabled ? 'Auto' : 'Off'
        configuration('Cameras SpeakerTrack', params({
            :Mode => value
        }), name: :speaker_track)
    end


    # Valid values: none, local, remote
    PresModes = {
        local: :LocalOnly,
        remote: :LocalRemote
    }
    def presentation_mode(value, source = @default_source)
        status = value.to_sym
        mode = PresModes[status]

        if mode
            command('Presentation Start', params({
                :SendingMode => mode,
                :PresentationSource => source
            }), name: :presentation).then do
                self[:presentation] = status
            end
        else
            command 'Presentation Stop'
            self[:presentation] = :none
        end
    end

    def content_available?
        status 'Conference Presentation Mode'
    end

    def select_camera(index)
        # NOTE:: Index should be a number
        command('Video Input SetMainVideoSource', params({
            :ConnectorId => index
        }), name: :select_camera)
    end

    def select_presentation(index)
        # NOTE: Index should be a number (generally 1-4)
        configuration('Video Presentation', params({
            :DefaultSource => index
        }), name: :select_presentation)
    end

    def video_output_mode(video_mode)
        # NOTE: video_mode should be "Single" or "Dual" or "Auto"
        configuration('Video', params({
            :Monitors => video_mode
        }), name: :video_output_mode)
        self[:video_output_mode] = video_mode
    end

    def video_output_mode?
        status 'Video Monitors'
    end

    # ====================
    # END Common functions
    # ====================

    def booking_list
        command 'bookings list'
    end


    # ===========================================
    # IR REMOTE KEYS (NOT AVAILABLE IN SX SERIES)
    # ===========================================

=begin
    RemoteKeys = ['0','1','2','3','4','5','6','7','8','9',
                  'Star','Square','Call','Disconnect',
                  'Up','Down','Right','Left','Selfview',
                  'Layout','PhoneBook','C','MuteMic','Presentation',
                  'VolumeUp','VolumeDown','Ok','ZoomIn','ZoomOut','Grab',
                  'F1','F2','F3','F4','F5','Home','Mute',
                  'SrcAux','SrcCamera','SrcDocCam','SrcPc','SrcVcr']

    #
    # Automatically creates a callable function for each command
    #   http://blog.jayfields.com/2007/10/ruby-defining-class-methods.html
    #   http://blog.jayfields.com/2008/02/ruby-dynamically-define-method.html
    #
    RemoteKeys.each do |key|
        define_method :"key_#{key.underscore}" do |**options|
            command("Key Click Key:#{key}", **options)
        end
    end
=end

    # ==================
    # END IR REMOTE KEYS
    # ==================


    def audio(*args, **options)
        command :audio, *args, params(options)
    end

    def history(cmd, options = {})
        command :CallHistroy, cmd, params(options)
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

    def wake(**options)
        command :Standby, :Deactivate, params(options)
    end

    def sleep_time(delay = 1)
        configuration('Standby', params({
            :Control => 'On'
        }), name: :standby)

        configuration('Standby', params({
            :Delay => delay
        }), name: :standby_delay)
    end

    def sleep(**options)
        command :Standby, :Activate, params(options)
    end

    ResponseType = {
        '**' => :complete,
        '*r' => :results,
        '*s' => :status
    }
    def received(data, resolve, command)
        logger.debug { "Tele sent #{data}" }

        result = Shellwords.split data
        response = ResponseType[result[0]]

        if command
            if response == :complete
                # Update status variables
                if @listing_bookings
                    @listing_bookings = false
                    update_booking_state
                elsif @listing_phonebook
                    @listing_phonebook = false

                    # expose results, unique every time
                    if @results.length > 0
                        @search_count ||= 0
                        @search_count += 1
                        @results[0][:count] = @search_count
                    end

                    self[:search_results] = @results if command[:name] != :extract
                elsif @call_status
                    @call_status[:id] = @last_call_id
                    self[:call_status] = @call_status
                    if @call_status.empty?
                        self[:incall] = false
                        self[:content_available] = false
                    else
                        self[:incall] = true
                        content_available?
                        if @call_status[:status] == 'OnHold'
                            self[:presentation] = :none
                        end
                    end
                    @call_status = nil
                elsif command[:name] == :call
                    if self[:call_status].present?
                        self[:previous_call] = self[:call_status][:callbacknumber]
                    end

                    self[:incall] = false
                    self[:presentation] = :none
                    self[:call_status] = {}
                    @last_call_id = nil
                    @call_status = nil
                end
                return :success
            elsif response.nil?
                return :ignore
            end
        end

        return case response
        when :status
            process_status result
        when :results
            process_results result
        else
            :success
        end
    end


    protected


    def update_booking_state
      time_now = Time.now.to_i
      current_booking = nil
      next_booking = nil
      additional_bookings = 0
      @current_booking_list.sort! { |a, b| a["time_start_time"] <=> b["time_start_time"] }
      @current_booking_list.each do |booking|
        next if booking["time_end_time"] < time_now
        start_time = booking["time_start_time"]

        if start_time <= time_now
          current_booking = booking
        elsif next_booking.nil?
          next_booking = booking
        else
          additional_bookings += 1
        end
      end
      self[:bookings] = @current_booking_list
      self[:booking_next] = next_booking
      self[:booking_current] = current_booking
      self[:additional_bookings] = additional_bookings
    end

    def process_results(result)
        case result[1].downcase.to_sym
        when :bookingslistresult
            if !@listing_bookings
              # configure the data structures
              case result[2].downcase
              when "resultinfo"
                @listing_bookings = true
                @current_booking_list = []
              when "lastupdated:"
                @listing_bookings = false if @bookings_last_updated == result[3]
                @bookings_last_updated = result[3]
              end
            elsif result[2].downcase == "booking"
              bindex = result[3].to_i - 1
              booking = @current_booking_list[bindex]
              if booking.nil?
                booking = {}
                @current_booking_list << booking
              end
              details = result[4..-1]
              value = details[-1]
              bkey = details[0..-2].join('').underscore.gsub(":", "")
              case result[-2].downcase
              when "starttime:", "endtime:"
                  booking[bkey] = Time.parse(value).to_i
              else
                  booking[bkey] = value
              end
            end
        when :phonebooksearchresult, :resultset
            @listing_phonebook = true

            case result[2]

            # Looks like: *r ResultSet ResultInfo TotalRows: 3
            when 'ResultInfo'
                if result[3] == 'TotalRows:'
                    self[:results_total] = result[4].to_i
                    @results = []
                end

            when 'Folder'
                contact = @results[result[3].to_i - 1]
                if contact.nil?
                    contact = {
                        contents: []
                    }
                    @results << contact
                end
                entry = result[4].chop
                contact[entry.underscore.to_sym] = result[5]

            when 'Contact'
                contact = @results[result[3].to_i - 1]
                if contact.nil?
                    contact = {
                        methods: []
                    }
                    @results << contact
                end

                if result[4] == 'ContactMethod'
                    # Looks like: *r ResultSet Contact 1 ContactMethod 1 Number: "10.243.218.232"
                    method = contact[:methods][result[5].to_i - 1]
                    if method.nil?
                        method = {}
                        contact[:methods] << method
                    end

                    entry = result[6].chop
                    method[entry.downcase.to_sym] = result[7]
                else
                    # Looks like: *r ResultSet Contact 2 Name: "Some Room"
                    entry = result[4].chop
                    contact[entry.downcase.to_sym] = result[5]
                end
            end
        end

        :ignore
    end

    def process_status(result)
        case result[1].downcase.to_sym
        when :call
            # Looks like: *s Call 32 CallbackNumber: "h323:10.243.218.234"

            @call_status ||= {}
            @last_call_id = result[2].to_i

            # NOTE: special case for "Encryption Type:"
            entry = result[3].chop.downcase.to_sym
            if entry == :encryptio
                @call_status[:encryption] = result[5]
            else
                @call_status[entry] = result[4]
            end
        when :conference
            if result[2] == 'Presentation' && result[3] == 'Mode:'
                self[:content_available] = result[4] != 'Off'
                if result[4] == 'Receiving'
                    # Then we are not sending anything
                    self[:presentation] = :none
                end
            end
        when :video
            case result[2]
                when 'Monitors:'
                    self[:video_output_mode] = result[3]
                when 'Selfview'
                    if result[3] == 'Mode:'
                        self[:camera_pip] = (result[4] == 'On')
                    end
            end
        when :audio
            if result[2] == 'Microphones' && result[3] == 'Mute:'
                self[:mute] = result[4] == 'On'
            end
        end

        :ignore
    end
end
