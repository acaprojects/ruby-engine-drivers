require 'savon'
require 'active_support/time'

module Gallagher; end

class Gallagher::Rest

    ##
    # Create a new instance of the Gallagher Rest client.
    #
    # @param domain [String] The domain to connect to this Gallagher instance with.
    # @param api_key [String] The API key to be included in the headers of each request in order to authenticate requests.
    # @param unique_pdf_name [String] The name of the personal data field used to align cardholders to staff members.
    # @param default_division [String] The division to pass when creating cardholders.
    def initialize(domain:, api_key:, unique_pdf_name: 'email', default_division: nil)
        # Initialize the http endpoint to make requests with our API key
        @default_headers = { Authorization: "GGL-API-KEY #{api_key}" }
        @default_division = default_division
        @endpoint = UV::HttpEndpoint.new(domain)

        # Grab the URLs to be used by the other methods (HATEOAS standard)
        # First define where we will find the URLs in the data endpoint's response
        data_endpoint = "/api"
        pdfs_href = "features.personalDatafields.personalDatafields.href"
        cardholders_href = "features.cardholders.cardholders.href"
        access_groups_href = "features.accessGroups.accessGroups.href"
        card_types_href = "features.cardTypes.assign.href"

        # Get the main data endpoint to determine our new endpoints
        response = @endpoint.get(path: data_endpoint, headers: @default_headers).value
        @cardholders_endpoint = response[cardholders_href]
        @pdfs_endpoint = response[pdfs_href]
        @access_groups_endpoint = response[access_groups_href]
        @card_types_endpoint = response[card_types_href]

        # Now get our cardholder PDF ID so we don't have to make the request over and over
        pdf_response = @endpoint.get(path: @pdfs_endpoint, headers: @default_headers, query: { name: unique_pdf_name }).value
        @fixed_pdf_id = pdf_response['results'][0]['id'] # There should only be one result
    end

    ##
    # Personal Data Fields (PDFs) are custom fields that Gallagher allows definintions of on a site-by-site basis.
    # They will usually be for things like email address, employee ID or some other field specific to whoever is hosting the Gallagher instance.
    # This method allows retrieval of the PDFs used in the Gallagher instance, primarily so we can get the PDF's ID and use that to filter cardholders based on that PDF.
    #
    # @param name [String] The name of the PDF which we want to retrieve. This will only return one result (as the PDF names are unique).
    # @return [Hash] A list of PDF results and a next link for pagination (we will generally have less than 100 PDFs so 'next' link will mostly be unused):
    # @example An example response:
    #    {
    #      "results": [
    #        {
    #          "name": "email",
    #          "id": "5516",
    #          "href": "https://localhost:8904/api/personal_data_fields/5516"    
    #        },
    #        {
    #          "name": "cellphone",
    #          "id": "9998",
    #          "href": "https://localhost:8904/api/personal_data_fields/9998",
    #          "serverDisplayName": "Site B"
    #        }
    #      ],
    #      "next": {
    #        "href": "https://localhost:8904/api/personal_data_fields?pos=900&sort=id"
    #      }
    #    }
    def get_pdfs(name: nil)
        # Add quotes around the value because da API bad
        name = "\"#{name}\"" if name
        @endpoint.get(path: @pdfs_endpoint, headers: @default_headers, query: {name: name}.compact).value
    end

    ##
    # Carholders are essentially users in the Gallagher system.
    # This method retrieves cardholders and allows for filtering either based on the PDF provided (by name) at initalisation of the library or by some custom filter.
    # For example, if the `unique_pdf_name` param passed in intialisation is `email` then passing `fixed_filter: 'some@email.com'` to this method will only return cardholders with that email.
    # If some other PDF is required for filtering, it can be used via the `custom_filter` param.
    #
    # @param fixed_filter [String] The value to be passed to the fixed PDF filter defined when this library is initialised. By default the PDF's name is `email`.
    # @param custom_filter [Hash] A PDF name and value to filter the cardholders by. For now this hash should only have one member.
    # @return [Hash] A list of cardholders and a next link for pagination (we will generally have less than 100 PDFs so 'next' link will mostly be unused):
    # @example An example response:
    #    {
    #      "results": [
    #        {
    #          "href": "https://localhost:8904/api/cardholders/10135",
    #          "id": "10135",
    #          "firstName": "Algernon",
    #          "lastName": "Boothroyd",
    #          "shortName": "Q",
    #          "description": "Quartermaster",
    #          "authorised": true
    #        }
    #      ],
    #      "next": {
    #        "href": "https://localhost:8904/api/cardholders?skip=61320"
    #      }
    #    }
    def get_cardholder(fixed_filter: nil, custom_filter: nil)
        query = {}
        # We can assume either fixed or custom filter may be used, but not both
        if fixed_filter
            query["pdf_#{@fixed_pdf_id}"] = "\"#{fixed_filter}\""
        elsif custom_filter
            # We need to first get the PDF's ID as it's not fixed (that's why it's custom duh lol)
            custom_pdf_id = self.get_pdfs(name: custom_filter.first[0].to_s)
            query["pdf_#{custom_pdf_id}"] = "\"#{custom_filter}\""
        end
        @endpoint.get(path: @cardholders_endpoint, headers: @default_headers, query: query).value
    end

    ##
    # Get a list of card types that this Gallagher instance has. These may include virutal, physical and ID cards.
    # Generally there are not going to be over 100 card types so the `next` field will be unused
    #
    # @return [Hash] An array of cards in the `results` field and a `next` field for pagination.
    # @example An example response:
    #    {
    #      "results": [
    #        {
    #          "href": "https://localhost:8904/api/card_types/600",
    #          "id": "600",
    #          "name": "Red DESFire visitor badge",
    #          "facilityCode": "A12345",
    #          "availableCardStates": [
    #            "Active",
    #            "Disabled (manually)",
    #            "Lost",
    #            "Stolen",
    #            "Damaged"
    #          ],
    #          "credentialClass": "card",
    #          "minimumNumber": "1",
    #          "maximumNumber": "16777215"
    #        }
    #      ],
    #      "next": {
    #        "href": "https://localhost:8904/api/card_types/assign?skip=100"
    #      }
    #    }
    def get_card_types
        @endpoint.get(path: @card_types_endpoint, headers: @default_headers).value
    end

    ##
    # Create a new cardholder.
    # @param first_name [String] The first name of the new cardholder. Either this or last name is required (but we should assume both are for most instances).
    # @param last_name [String] The last name of the new cardholder. Either this or first name is required (but we should assume both are for most instances).
    # @option options [String] :division The division to add the cardholder to. This is required when making the request to create the cardholder but if none is passed the `default_division` is used.
    # @option options [Hash] :pdfs A hash containing all PDFs to add to the user in the form `{ some_pdf_name: some_pdf_value, another_pdf_name: another_pdf_value }`.
    # @option options [Array] :cards An array of cards to be added to this cardholder which can include both virtual and physical cards.
    # @option options [Array] :access_groups An array of access groups to add this cardholder to. These may include `from` and `until` fields to dictate temporary access.
    # @option options [Array] :competencies An array of competencies to add this cardholder to.
    # @return [Hash] The cardholder that was created.
    def create_cardholder(first_name:, last_name:, options: {})
        default_options = {
            division: @default_division,
            pdfs: nil,
            cards: nil,
            access_groups: nil,
            competencies: nil
        }

        # Merge in our default options with those passed in
        options = options.reverse_merge(default_options)

        # Format the division correctly
        options[:division] = {
            href: options[:division]
        }

        # The params we're actually passing to Gallagher for creation
        create_params = {
            firstName: first_name,
            lastName: last_name,
            shortName: "#{first_name} #{last_name}"
        }

        # Add in our passed PDFs appending an '@' to the start of each pdf name
        options[:pdfs].each do |pdf_name, pdf_value|
            create_params["@#{pdf_name}".to_sym] = pdf_value
        end

        # Add in any passed options, converting the keys to camel case which Gallagher uses
        create_params.merge(options.except(:pdfs).transform_keys{|k| k.to_s.camelize(:lower)})

        # Create our cardholder and return the response
        @endpoint.post(path: @cardholders_endpoint, headers: @default_headers, body: create_params).value
    end

    ##
    # This method will take card details and return a hash card detils aligning with the passed parameters in the format Gallagher expects
    #
    # @example An example response:
    #    {
    #      "number": "Nick's mobile",
    #      "status": {
    #        "value": "active"
    #      },
    #      "type": {
    #        "https://localhost:8904/api/card_types/654": null
    #      },
    #      "from": "2017-01-01T00:00:00Z",
    #      "until": "2018-01-01T00:00:00Z",
    #      "invitation": {
    #        "email": "nick@example.com",
    #        "mobile": "02123456789",
    #        "singleFactorOnly": true
    #      }
    #    }
    # @param card_href [String] This defines the type of card and can be pulled from the `get_card_types` method.
    # @option options [String] :number The card number to create. If physical you can omit this as it will use a default number. If mobile this can be anything.
    # @option options [Integer] :from An epoch denoting the time to start access from.
    # @option options [Integer] :until An epoch denoting the time to start access until.
    # @option options [String] :email An email to send a mobile credential invitation to.
    # @option options [Integer] :mobile A mobile number to associate a mobile credential with.
    # @return [Hash] The passed in card formatted for Gallagher.
    def format_card(card_href:, options: {})
        default_options = {
            number: nil,
            from: nil,
            until: nil,
            email: nil,
            mobile: nil
        }

        # Merge in our default options with those passed in
        options = options.reverse_merge(default_options)

        formatted_card = {
            type: {
                href:  card_href
            }
        }
        formatted_card[:number] = options[:number] if options[:number]
        formatted_card[:from] = Time.at(options[:from]).utc.iso8601 if options[:from]
        formatted_card[:until] = Time.at(options[:until]).utc.iso8601 if options[:until]
        formatted_card[:invitation] = {
            email: options[:email],
            mobile: options[:mobile],
            singleFactorOnly: true
        } if options[:email]
        formatted_card
    end

    ##
    # This method updates an existing cardholder to add new cards, access groups or competencies.
    # We will often have to add a card and an access group to a user so doing these at the same time should save on requests.
    # For now the `from` and `until` params will apply to all fields in the update.
    #
    # @param cardholder_href [String] The ID of the cardholder inside the URL used to update it. This can be retreived from a cardholders GET.
    # @option options [Array] :cards An array of cards to be added. These should at least have the `type.href` field set.
    # @option options [Array] :access_groups An array of access_groups to be added. These should at least have the `accessGroup.href` field set.
    # @option options [Array] :competencies An array of competencies to be added. These should at least have the `competency.href` field set.
    # @return [Hash] The cardholder that access was added for.
    def add_cardholder_access(cardholder_href:, options: {})
        self.update_cardholder(type: :add, cardholder_href: cardholder_href, options: options)
    end

    ##
    # This method updates an existing cardholder to update new cards, access groups or competencies.
    # We will often have to add a card and an access group to a user so doing these at the same time should save on requests.
    # For now the `from` and `until` params will apply to all fields in the update.
    #
    # @param cardholder_href [String] The ID of the cardholder inside the URL used to update it. This can be retreived from a cardholders GET.
    # @option options [Array] :cards An array of cards to be added. These should at least have the `type.href` field set.
    # @option options [Array] :access_groups An array of access_groups to be added. These should at least have the `accessGroup.href` field set.
    # @option options [Array] :competencies An array of competencies to be added. These should at least have the `competency.href` field set.
    # @return [Hash] The cardholder that access was added for.
    def update_cardholder_access(cardholder_href:, options: {})
        self.update_cardholder(type: :update, cardholder_href: cardholder_href, options: options)
    end

    ##
    # This method updates an existing cardholder to remove new cards, access groups or competencies.
    # We will often have to add a card and an access group to a user so doing these at the same time should save on requests.
    # For now the `from` and `until` params will apply to all fields in the update.
    #
    # @param cardholder_href [String] The ID of the cardholder inside the URL used to update it. This can be retreived from a cardholders GET.
    # @option options [Array] :cards An array of cards to be added. These should at least have the `type.href` field set.
    # @option options [Array] :access_groups An array of access_groups to be added. These should at least have the `accessGroup.href` field set.
    # @option options [Array] :competencies An array of competencies to be added. These should at least have the `competency.href` field set.
    # @return [Hash] The cardholder that access was added for.
    def remove_cardholder_access(cardholder_href:, options: {})
        self.update_cardholder(type: :remove, cardholder_href: cardholder_href, options: options)
    end 

    protected

    def update_cardholder(type:, cardholder_href:, options: {})
        default_options = {
            cards: nil,
            access_groups: nil,
            competencies: nil
        }

        # Merge in our default options with those passed in
        options = options.reverse_merge(default_options)

        # Align to their kinda shitty format
        patch_params = {
            authorised: true
        }

        # Add the fields to update if they were passed in
        options.except(:from, :until).each do |param, value|
            patch_params[param.to_s.camelize(:lower)] = { type => value } if value
        end

        @endpoint.patch(path: cardholder_href, headers: @default_headers, body: patch_params).value
    end 
end