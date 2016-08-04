module Aca; end
module Aca::Meetings; end


require 'viewpoint2'
require 'nokogiri'


class Aca::Meetings::EwsAppender
    def initialize(uri, user, password, callback = nil, &blk)
        @callback = callback || blk

        # Create our EWS Client
        @cli = Viewpoint::EWSClient.new uri, user, password, { "http_opts": { "ssl_verify_mode": 0 } }
        @moderator = Viewpoint::EWSClient.new uri, user, password, { "http_opts": { "ssl_verify_mode": 0 } }
        @appender = self
    end

    attr_reader :cli

    def moderate_bookings
        # Get our bookings
        attachments = self.find_attachments

        email_ids = {}

        attachments.each { |a|
            email_ids[a[:uid]] ||= []
            email_ids[a[:uid]].push(a[:item])
        }

        # Get to the point where we 
        attachments.map { |e|
            {
                organizer: e[:organizer],
                uid: e[:uid],
                location: e[:location],
                attendees: e[:attendees],
                start: e[:start],
                end: e[:end],
                resources: e[:resources],
                booking_id: e[:booking_id],
                subject: e[:subject]
            }
        }.uniq.each{ |a|
            a[:moderation_emails] = email_ids[a[:uid]]
            @callback.call(a, @appender)
        }
    end

    def append_booking(request, additional_content)
        # Impersonate the organizer so that we can retrieve the right calendar items
        @cli.set_impersonation(Viewpoint::EWS::ConnectingSID[:SMTP], request[:organizer])
        booking = @cli.get_item(request[:booking_id], { :item_shape => { :base_shape => 'AllProperties' } })

        # Grab the body of the booking and parse it
        html_doc = Nokogiri::HTML(booking.body)

        # Add the appended text (assumes that content will be contained in a table)
        html_doc.at('body').children.last.after("<br /><br />#{additional_content}")

        # Add our input and update the item
        booking.update_item!({:body => html_doc.to_html}, {:send_meeting_invitations_or_cancellations => 'SendToAllAndSaveCopy'})

        # Delete all emails relating to this booking
        request[:moderation_emails].each do |item|
            item.delete!
        end
    end

    def update_booking(organizer, booking_id, indicator, dial_in_text, send_update = 'SendToAllAndSaveCopy')
        # Impersonate the organizer so that we can retrieve the right calendar items
        @cli.set_impersonation(Viewpoint::EWS::ConnectingSID[:SMTP], organizer)
        booking = @cli.get_item(booking_id, { :item_shape => { :base_shape => 'AllProperties' } })

        # Grab the body of the booking and parse it
        html_doc = Nokogiri::HTML(booking.body)

        # We actually want the largest table element that contains the text
        # as tables can contain sub-tables and tables are not modified by exchange so much
        el = nil
        html_doc.css('table').each do |element|
            text = element.inner_html
            if text =~ /#{indicator}/
                el = element
                break
            end
        end

        if el
            el.replace("#{dial_in_text}")
        else
            html_doc.at('body').children.last.after("<br /><br />#{dial_in_text}")
        end

        # Add our input and update the item
        booking.update_item!({:body => html_doc.to_html}, {:send_meeting_invitations_or_cancellations => send_update})
    end

    # Just a little helper method to retreive fields from EWS reponses
    def get_elem(elems, key) 
        elems.each do |elem|
            if elem[key]
              if key == :resources
                return elem[key]
              elsif key == :required_attendees
                return elem[key]
              elsif key == :organizer
                 return get_elem(elem[key][:elems][0][:mailbox][:elems], :email_address)
              elsif key == :conversation_id
                 return elem[key][:attribs][:id]
              else
                 return elem[key][:text]
              end
            end
        end
    end

    def get_resources(attachment)
        # Get the organiser's calendar ID
        @cli.set_impersonation(Viewpoint::EWS::ConnectingSID[:SMTP], attachment[:organizer])
        calendar_id = @cli.get_folder(:calendar).id

        calendar_items = @cli.find_items folder_id: calendar_id, shape: :id_only do |query|
            query.restriction = {
                is_equal_to: [
                {
                    "field_uRI" => "calendar:Start",
                    "field_uRI_or_constant" => {
                        constant: { value:  attachment[:start] }
                    }
                }]
            }
        end

        calendar_items.each do |booking|
            if booking.get_all_properties![:u_i_d][:text] == attachment[:uid]
                resource_booking = @cli.get_item(booking.id, { :item_shape => { :additional_properties => { :field_uRI => 'calendar:Resources'}, :base_shape => 'AllProperties'}})
                # elems = resource_booking.attachments[0].get_all_properties![:meeting_request][:elems]
                elems = resource_booking.ews_item[:resources]
                resources = if elems 
                    elems[:elems].map{ |e| e[:attendee][:elems][0][:mailbox][:elems][1][:email_address][:text] }
                else
                    []
                end

                return [resources, booking]
            end
        end

        return [[], nil]
    end


    protected


    def find_attachments
        inbox = @moderator.get_folder(:inbox)
        attachments  = []
        # For all the messages from today
        inbox.todays_items.each do |item|

            # Ensure that these are meeting requests
            if item.attachments[0].get_all_properties![:meeting_request]

                # Get all the emails of the attendees
                attendee_list = get_elem(item.attachments[0].get_all_properties![:meeting_request][:elems], :required_attendees)[:elems]
                attendees = attendee_list.map{|e| e[:attendee][:elems][0][:mailbox][:elems][1][:email_address][:text]}

                # Record the details of the attachment so we can find them in the organiser's calendar
                elems = item.attachments[0].get_all_properties![:meeting_request][:elems]
                attachment = {
                    :attendees => attendees,
                    :email_id => item.id,
                    :uid => get_elem(elems, :u_i_d),
                    :organizer => get_elem(elems, :organizer),
                    :location => get_elem(elems, :location),
                    :subject => get_elem(elems, :subject),
                    :start => get_elem(elems, :start),
                    :end => get_elem(elems, :end),
                    :item => item
                }

                resources, booking = get_resources(attachment)
                next if resources.empty? || booking.nil?
                
                attachment[:resources] = resources
                attachment[:booking_id] = booking.id

                attachments.push(attachment)
            end
        end

        return attachments
    end
end
