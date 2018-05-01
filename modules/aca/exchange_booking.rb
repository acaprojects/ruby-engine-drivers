# For rounding up to the nearest 15min
# See: http://stackoverflow.com/questions/449271/how-to-round-a-time-down-to-the-nearest-15-minutes-in-ruby
class ActiveSupport::TimeWithZone
    def ceil(seconds = 60)
        return self if seconds.zero?
        Time.at(((self - self.utc_offset).to_f / seconds).ceil * seconds).in_time_zone + self.utc_offset
    end
end

require 'microsoft/exchange'

module Aca; end

# NOTE:: Requires Settings:
# ========================
# room_alias: 'rs.au.syd.L16Aitken',
# building: 'DP3',
# level: '16'

class Aca::ExchangeBooking
    include ::Orchestrator::Constants
    EMAIL_CACHE = ::Concurrent::Map.new
    CAN_LDAP = begin
        require 'net/ldap'
        true
    rescue LoadError
        false
    end
    CAN_EWS = begin
        require 'viewpoint2'
        true
    rescue LoadError
        begin
            require 'viewpoint'
            true
        rescue LoadError
            false
        end
        false
    end


    descriptive_name 'Exchange Room Bookings'
    generic_name :Bookings
    implements :logic


    # The room we are interested in
    default_settings({
        update_every: '2m',

        # Moved to System or Zone Setting
        # cancel_meeting_after: 900

        # Card reader IDs if we want to listen for swipe events
        card_readers: ['reader_id_1', 'reader_id_2'],

        # Optional LDAP creds for looking up emails
        ldap_creds: {
            host: 'ldap.org.com',
            port: 636,
            encryption: {
                method: :simple_tls,
                tls_options: {
                    verify_mode: 0
                }
            },
            auth: {
                  method: :simple,
                  username: 'service account',
                  password: 'password'
            }
        },
        tree_base: "ou=User,ou=Accounts,dc=org,dc=com",

        # Optional EWS for creating and removing bookings
        ews_creds: [
            'https://company.com/EWS/Exchange.asmx',
            'service account',
            'password',
            { http_opts: { ssl_verify_mode: 0 } }
        ],
        ews_room: 'room@email.address'
    })


    def on_load
        on_update
    end

    def on_update
        self[:swiped] ||= 0
        @last_swipe_at = 0
        @use_act_as = setting(:use_act_as)

        self[:hide_all] = setting(:hide_all) || false
        self[:touch_enabled] = setting(:touch_enabled) || false
        self[:name] = self[:room_name] = setting(:room_name) || system.name
        self[:description] = setting(:description) || nil
        self[:title] = setting(:title) || nil
        self[:timeout] = setting(:timeout) || false

        self[:control_url] = setting(:booking_control_url) || system.config.support_url
        self[:booking_controls] = setting(:booking_controls)
        self[:booking_catering] = setting(:booking_catering)
        self[:booking_hide_details] = setting(:booking_hide_details)
        self[:booking_hide_availability] = setting(:booking_hide_availability)
        self[:booking_hide_user] = setting(:booking_hide_user)
        self[:booking_hide_description] = setting(:booking_hide_description)
        self[:booking_hide_timeline] = setting(:booking_hide_timeline)
        self[:last_meeting_started] = setting(:last_meeting_started)
        self[:cancel_meeting_after] = setting(:cancel_meeting_after)
        self[:booking_min_duration] = setting(:booking_min_duration)
        self[:booking_disable_future] = setting(:booking_disable_future)
        self[:booking_max_duration] = setting(:booking_max_duration)
        self[:timeout] = setting(:timeout)

        @check_meeting_ending = setting(:check_meeting_ending) # seconds before meeting ending
        @extend_meeting_by = setting(:extend_meeting_by) || 15.minutes.to_i

        # Skype join button available 2min before the start of a meeting
        @skype_start_offset = setting(:skype_start_offset) || 120

        # Skype join button not available in the last 8min of a meeting
        @skype_end_offset = setting(:skype_end_offset) || 480
        @force_skype_extract = setting(:force_skype_extract)

        # Because restarting the modules results in a 'swipe' of the last read card
        ignore_first_swipe = true

        # Is there catering available for this room?
        self[:catering] = setting(:catering_system_id)
        if self[:catering]
            self[:menu] = setting(:menu)
        end

        # Do we want to look up the users email address?
        if CAN_LDAP
            @ldap_creds = setting(:ldap_creds)
            if @ldap_creds
                encrypt = @ldap_creds[:encryption]
                encrypt[:method] = encrypt[:method].to_sym if encrypt && encrypt[:method]
                @tree_base = setting(:tree_base)
                @ldap_user = @ldap_creds.delete :auth
            end
        else
            logger.warn "net/ldap gem not available" if setting(:ldap_creds)
        end

        # Do we want to use exchange web services to manage bookings
        if CAN_EWS
            @ews_creds = setting(:ews_creds)
            @ews_room = (setting(:ews_room) || system.email) if @ews_creds
            # supports: SMTP, PSMTP, SID, UPN (user principle name)
            # NOTE:: Using UPN we might be able to remove the LDAP requirement
            @ews_connect_type = (setting(:ews_connect_type) || :SMTP).to_sym
            @timezone = setting(:room_timezone)
        else
            logger.warn "viewpoint gem not available" if setting(:ews_creds)
        end

        # Load the last known values (persisted to the DB)
        self[:waiter_status] = (setting(:waiter_status) || :idle).to_sym
        self[:waiter_call] = self[:waiter_status] != :idle

        self[:catering_status] = setting(:last_catering_status) || {}
        self[:order_status] = :idle

        self[:last_meeting_started] = setting(:last_meeting_started)
        self[:cancel_meeting_after] = setting(:cancel_meeting_after)


        # unsubscribe to all swipe IDs if any are subscribed
        if @subs.present?
            @subs.each do |sub|
                unsubscribe(sub)
            end

            @subs = nil
        end

        # Are there any swipe card integrations
        if system.exists? :Security
            readers = setting(:card_readers)
            if readers.present?
                security = system[:Security]

                readers = readers.is_a?(Array) ? readers : [readers]
                sys = system
                @subs = []
                readers.each do |id|
                    @subs << sys.subscribe(:Security, 1, id.to_s) do |notice|
                        if ignore_first_swipe
                            ignore_first_swipe = false
                        else
                            swipe_occured(notice.value)
                        end
                    end
                end
            end
        end

        schedule.clear
        schedule.in(rand(10000)) { fetch_bookings }
        schedule.every((setting(:update_every) || 120000).to_i + rand(10000)) { fetch_bookings }
    end


    def set_light_status(status)
        lightbar = system[:StatusLight]
        return if lightbar.nil?

        case status.to_sym
        when :unavailable
            lightbar.colour(:red)
        when :available
            lightbar.colour(:green)
        when :pending
            lightbar.colour(:orange)
        else
            lightbar.colour(:off)
        end
    end

    def directory_search(q, limit: 30)
        # Ensure only a single search is occuring at a time
        if @dir_search
            @dir_search = q
            return
        end

        ews = ::Microsoft::Exchange.new({
            ews_url: ENV['EWS_URL'] || 'https://outlook.office365.com/ews/Exchange.asmx',
            service_account_email: ENV['OFFICE_ACCOUNT_EMAIL'],
            service_account_password: ENV['OFFICE_ACCOUNT_PASSWORD'],
            internet_proxy: ENV['INTERNET_PROXY']
        })

        @dir_search = q
        self[:searching] = true
        begin
            # sip_spd:Auto sip_num:email@address.com
            entries = []
            task { ews.get_users(q: q, limit: limit) }.value.each do |entry|
                phone = entry['phone']

                entries << entry
                entries << ({
                    name: entry['name'],
                    phone: phone.gsub(/\D+/, '')
                }) if phone
            end

            # Ensure the results are unique and pushed to the client
            entries[0][:id] = rand(10000) if entries.length > 0
            self[:directory] = entries
        rescue => e
            logger.print_error e, 'searching directory'
            self[:directory] = []
        end

        # Update the search if a change was requested while a search was occuring
        if @dir_search != q
            q = @dir_search
            thread.next_tick { directory_search(q, limit) }
        else
            self[:searching] = false
        end

        @dir_search = nil
    end

    # ======================================
    # Waiter call information
    # ======================================
    def waiter_call(state)
        status = is_affirmative?(state)

        self[:waiter_call] = status

        # Used to highlight the service button
        if status
            self[:waiter_status] = :pending
        else
            self[:waiter_status] = :idle
        end

        define_setting(:waiter_status, self[:waiter_status])
    end

    def call_acknowledged
        self[:waiter_status] = :accepted
        define_setting(:waiter_status, self[:waiter_status])
    end


    # ======================================
    # Catering Management
    # ======================================
    def catering_status(details)
        self[:catering_status] = details

        # We'll turn off the green light on the waiter call button
        if self[:waiter_status] != :idle && details[:progress] == 'visited'
            self[:waiter_call] = false
            self[:waiter_status] = :idle
            define_setting(:waiter_status, self[:waiter_status])
        end

        define_setting(:last_catering_status, details)
    end

    def commit_order(order_details)
        self[:order_status] = :pending
        status = self[:catering_status]

        if status && status[:progress] == 'visited'
            status = status.dup
            status[:progress] = 'cleaned'
            self[:catering_status] = status
        end

        if self[:catering]
            sys = system
            @oid ||= 1
            systems(self[:catering])[:Orders].add_order({
                id: "#{sys.id}_#{@oid}",
                created_at: Time.now.to_i,
                room_id: sys.id,
                room_name: sys.name,
                order: order_details
            })
        end
    end

    def order_accepted
        self[:order_status] = :accepted
    end

    def order_complete
        self[:order_status] = :idle
    end



    # ======================================
    # ROOM BOOKINGS:
    # ======================================
    def fetch_bookings(*args)
        logger.debug { "looking up todays emails for #{@ews_room}" }
        task {
            todays_bookings
        }.then(proc { |bookings|
            self[:today] = bookings
            if @check_meeting_ending
                should_notify?
            end
        }, proc { |e| logger.print_error(e, 'error fetching bookings') })
    end


    # ======================================
    # Meeting Helper Functions
    # ======================================

    def start_meeting(meeting_ref)
        self[:last_meeting_started] = meeting_ref
        self[:meeting_pending] = meeting_ref
        self[:meeting_ending] = false
        self[:meeting_pending_notice] = false
        define_setting(:last_meeting_started, meeting_ref)
    end

    def cancel_meeting(start_time)
        task {
            if start_time.class == Integer
                delete_ews_booking (start_time / 1000).to_i
            else
                # Converts to time object regardless of start_time being string or time object
                start_time = Time.parse(start_time.to_s)
                delete_ews_booking start_time.to_i
            end
        }.then(proc { |count|
            logger.debug { "successfully removed #{count} bookings" }

            self[:last_meeting_started] = start_time
            self[:meeting_pending] = start_time
            self[:meeting_ending] = false
            self[:meeting_pending_notice] = false
        }, proc { |error|
            logger.print_error error, 'removing ews booking'
        })
    end

    # If last meeting started !== meeting pending then
    #  we'll show a warning on the in room touch panel
    def set_meeting_pending(meeting_ref)
        self[:meeting_ending] = false
        self[:meeting_pending] = meeting_ref
        self[:meeting_pending_notice] = true
    end

    # Meeting ending warning indicator
    # (When meeting_ending !== last_meeting_started then the warning hasn't been cleared)
    # The warning is only displayed when meeting_ending === true
    def set_end_meeting_warning(meeting_ref = nil, extendable = false)
        if self[:last_meeting_started].nil? || self[:meeting_ending] != (meeting_ref || self[:last_meeting_started])
            self[:meeting_ending] = true

            # Allows meeting ending warnings in all rooms
            self[:last_meeting_started] = meeting_ref if meeting_ref
            self[:meeting_canbe_extended] = extendable
        end
    end

    def clear_end_meeting_warning
        self[:meeting_ending] = self[:last_meeting_started]
    end
    # ---------

    def create_meeting(options)
        # Check that the required params exist
        required_fields = [:start, :end]
        check = required_fields - options.keys.collect(&:to_sym)
        if check != []
            # There are missing required fields
            logger.info "Required fields missing: #{check}"
            raise "missing required fields: #{check}"
        end


        req_params = {}
        req_params[:room_email] = @ews_room
        req_params[:subject] = options[:title]
        req_params[:start_time] = Time.at(options[:start].to_i / 1000).utc.iso8601.chop
        req_params[:end_time] = Time.at(options[:end].to_i / 1000).utc.iso8601.chop

        task {
            username = options[:user]
            if username.present?

                user_email = ldap_lookup_email(username)
                if user_email
                    req_params[:user_email] = user_email
                    make_ews_booking req_params
                else
                    raise "couldn't find user: #{username}"
                end

            else
                make_ews_booking req_params
            end
        }.then(proc { |id|
            logger.debug { "successfully created booking: #{id}" }
            "Ok"
        }, proc { |error|
            logger.print_error error, 'creating ad hoc booking'
            thread.reject error # propogate the error
        })
    end

    def should_notify?
        bookings = self[:today]
        return unless bookings.present?
        now = Time.now.to_i

        current = nil
        pending = nil
        found = false

        bookings.sort! { |a, b| a[:end_epoch] <=> b[:end_epoch] }
        bookings.each do |booking|
            starting = booking[:start_epoch]
            ending = booking[:end_epoch]

            if starting < now && ending > now
                found = true
                current = ending
                @current_meeting_title = booking[:Subject]
            elsif found
                pending = starting
                break
            end
        end

        if !current
            self[:meeting_canbe_extended] = false
            return
        end

        check_start = current - @check_meeting_ending
        check_extend = current + @extend_meeting_by

        if now >= check_start && (pending.nil? || pending >= check_extend)
            self[:meeting_canbe_extended] = current
        else
            self[:meeting_canbe_extended] = false
        end
    end

    def extend_meeting
        starting = self[:meeting_canbe_extended]
        return false unless starting

        ending = starting + @extend_meeting_by
        create_meeting start: starting * 1000, end: ending * 1000, title: @current_meeting_title
    end


    protected


    def swipe_occured(info)
        # Update the user details
        @last_swipe_at = Time.now.to_i
        self[:fullname] = "#{info[:firstname]} #{info[:lastname]}"
        self[:username] = info[:staff_id]
        email = nil

        if self[:username] && @ldap_creds
            email = EMAIL_CACHE[self[:username]]
            if email
                set_email(email)
                logger.debug { "email #{email} found in cache" }
            else
                # Cache username here as self[:username] might change while we
                #  looking up the previous username
                username = self[:username]

                logger.debug { "looking up email for #{username} - #{self[:fullname]}" }
                task {
                    ldap_lookup_email username
                }.then do |email|
                    if email
                        logger.debug { "email #{email} found in LDAP" }
                        EMAIL_CACHE[username] = email
                        set_email(email)
                    else
                        logger.warn "no email found in LDAP for #{username}"
                        set_email nil
                    end
                end
            end
        else
            logger.warn "no staff ID for user #{self[:fullname]}"
            set_email nil
        end
    end

    def set_email(email)
        self[:email] = email
        self[:swiped] += 1
    end

    # ====================================
    # LDAP lookup to occur in worker thread
    # ====================================
    def ldap_lookup_email(username)
        email = EMAIL_CACHE[username]
        return email if email

        ldap = Net::LDAP.new @ldap_creds
        ldap.authenticate @ldap_user[:username], @ldap_user[:password] if @ldap_user

        login_filter = Net::LDAP::Filter.eq('sAMAccountName', username)
        object_filter = Net::LDAP::Filter.eq('objectClass', '*')
        treebase = @tree_base
        search_attributes = ['mail']

        email = nil
        ldap.bind
        ldap.search({
            base: treebase,
            filter: object_filter & login_filter,
            attributes: search_attributes
        }) do |entry|
            email = get_attr(entry, 'mail')
        end

        # Returns email as a promise
        EMAIL_CACHE[username] = email
        email
    end

    def get_attr(entry, attr_name)
        if attr_name != "" && attr_name != nil
            entry[attr_name].is_a?(Array) ? entry[attr_name].first : entry[attr_name]
        end
    end
    # ====================================


    # =======================================
    # EWS Requests to occur in a worker thread
    # =======================================
    def make_ews_booking(user_email: nil, subject: 'On the spot booking', room_email:, start_time:, end_time:)
        user_email ||= self[:email]  # if swipe card used

        booking = {
            subject: subject,
            start: start_time,
            end: end_time
        }

        if user_email
            booking[:required_attendees] = [{
                attendee: { mailbox: { email_address: user_email } }
            }]
        end

        cli = Viewpoint::EWSClient.new(*@ews_creds)
        opts = {}

        if @use_act_as
            opts[:act_as] = @ews_room if @ews_room
        else
            cli.set_impersonation(Viewpoint::EWS::ConnectingSID[@ews_connect_type], @ews_room) if @ews_room
        end

        folder = cli.get_folder(:calendar, opts)
        appointment = folder.create_item(booking)

        # Return the booking IDs
        appointment.item_id
    end

    def delete_ews_booking(delete_at)
        now = Time.now
        if @timezone
            start  = now.in_time_zone(@timezone).midnight
            ending = now.in_time_zone(@timezone).tomorrow.midnight
        else
            start  = now.midnight
            ending = now.tomorrow.midnight
        end

        count = 0

        cli = Viewpoint::EWSClient.new(*@ews_creds)

        if @use_act_as
            # TODO:: think this line can be removed??
            # delete_at = Time.parse(delete_at.to_s).to_i

            opts = {}
            opts[:act_as] = @ews_room if @ews_room

            folder = cli.get_folder(:calendar, opts)
            items = folder.items({:calendar_view => {:start_date => start.utc.iso8601, :end_date => ending.utc.iso8601}})
        else
            cli.set_impersonation(Viewpoint::EWS::ConnectingSID[@ews_connect_type], @ews_room) if @ews_room
            items = cli.find_items({:folder_id => :calendar, :calendar_view => {:start_date => start.utc.iso8601, :end_date => ending.utc.iso8601}})
        end

        items.each do |meeting|
            meeting_time = Time.parse(meeting.ews_item[:start][:text])

            # Remove any meetings that match the start time provided
            if meeting_time.to_i == delete_at
                meeting.delete!(:recycle, send_meeting_cancellations: 'SendOnlyToAll')
                count += 1
            end
        end

        # Return the number of meetings removed
        count
    end

    def todays_bookings
        now = Time.now
        if @timezone
            start  = now.in_time_zone(@timezone).midnight
            ending = now.in_time_zone(@timezone).tomorrow.midnight
        else
            start  = now.midnight
            ending = now.tomorrow.midnight
        end

        cli = Viewpoint::EWSClient.new(*@ews_creds)
        

        if @use_act_as
            opts = {}
            opts[:act_as] = @ews_room if @ews_room

            folder = cli.get_folder(:calendar, opts)
            items = folder.items({:calendar_view => {:start_date => start.utc.iso8601, :end_date => ending.utc.iso8601}})
        else
            cli.set_impersonation(Viewpoint::EWS::ConnectingSID[@ews_connect_type], @ews_room) if @ews_room
            items = cli.find_items({:folder_id => :calendar, :calendar_view => {:start_date => start.utc.iso8601, :end_date => ending.utc.iso8601}})
        end

        skype_exists = set_skype_url = system.exists?(:Skype)
        set_skype_url = true if @force_skype_extract
        now_int = now.to_i

        items.select! { |booking| !booking.cancelled? }
        results = items.collect do |meeting|
            item = meeting.ews_item
            start = item[:start][:text]
            ending = item[:end][:text]

            real_start = Time.parse(start)
            real_end = Time.parse(ending)

            # Extract the skype meeting URL
            if set_skype_url
                start_integer = real_start.to_i - @skype_start_offset
                end_integer = real_end.to_i - @skype_end_offset

                if now_int > start_integer && now_int < end_integer
                    meeting.get_all_properties!

                    if meeting.body
                        # Lync: <a name="OutJoinLink">
                        # Skype: <a name="x_OutJoinLink">
                        body_parts = meeting.body.split('OutJoinLink"')
                        if body_parts.length > 1
                            links = body_parts[-1].split('"').select { |link| link.start_with?('https://') }
                            if links[0].present?
                                self[:can_join_skype_meeting] = true
                                set_skype_url = false
                                system[:Skype].set_uri(links[0]) if skype_exists
                            end
                        end
                    end
                end

                if @timezone
                    start = real_start.in_time_zone(@timezone).iso8601[0..18]
                    ending = real_end.in_time_zone(@timezone).iso8601[0..18]
                end
            elsif @timezone
                start = Time.parse(start).in_time_zone(@timezone).iso8601[0..18]
                ending = Time.parse(ending).in_time_zone(@timezone).iso8601[0..18]
            end

            logger.debug { item.inspect }

            # Prevent connections handing with TIME_WAIT
            # cli.ews.connection.httpcli.reset_all

            subject = item[:subject]

            {
                :Start => start,
                :End => ending,
                :Subject => subject ? subject[:text] : "Private",
                :owner => item[:organizer][:elems][0][:mailbox][:elems][0][:name][:text],
                :setup => 0,
                :breakdown => 0,
                :start_epoch => real_start.to_i,
                :end_epoch => real_end.to_i
            }
        end

        if set_skype_url
            self[:can_join_skype_meeting] = false
            system[:Skype].set_uri(nil) if skype_exists
        end

        results
    end
    # =======================================
end
