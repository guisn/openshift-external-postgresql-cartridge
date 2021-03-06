class ApplicationsController < BaseController
  respond_to :xml, :json
  before_filter :authenticate, :check_version
  include LegacyBrokerHelper
  include CartridgeHelper
  # GET /domains/[domain id]/applications
  def index
    domain_id = params[:domain_id]

    domain = Domain.get(@cloud_user, domain_id)
    return render_error(:not_found, "Domain '#{domain_id}' not found", 127,
                        "LIST_APPLICATIONS") if !domain || !domain.hasAccess?(@cloud_user)

    @domain_name = domain.namespace
    applications = Application.find_all(@cloud_user)
    apps = Array.new
    include_cartridges = (params[:include] == "cartridges")
    
    applications.each do |application|
      if application.domain.uuid = domain.uuid
        if $requested_api_version == 1.0
          app = RestApplication10.new(application, get_url, nolinks)
        elsif $requested_api_version < 1.3
          app = RestApplication12.new(application, get_url, nolinks)
        else
          app = RestApplication.new(application, get_url, nolinks)
        end
        if include_cartridges
          app.cartridges = get_cartridges(application)
        end
        apps.push(app)
      end
    end if applications
    render_success(:ok, "applications", apps, "LIST_APPLICATIONS", "Found #{apps.length} applications for domain '#{domain_id}'")
  end
  
  # GET /domains/[domain_id]/applications/<id>
  def show
    domain_id = params[:domain_id]
    id = params[:id]
    
    domain = Domain.get(@cloud_user, domain_id)
    return render_error(:not_found, "Domain '#{domain_id}' not found", 127,
                        "SHOW_APPLICATION") if !domain || !domain.hasAccess?(@cloud_user)

    @domain_name = domain.namespace
    application = get_application(id)
    return render_error(:not_found, "Application '#{id}' not found", 101,
                        "SHOW_APPLICATION") if !application or application.domain.uuid != domain.uuid

    @application_name = application.name
    @application_uuid = application.uuid
    if $requested_api_version == 1.0
      app = RestApplication10.new(application, get_url, nolinks)
    elsif $requested_api_version < 1.3
      app = RestApplication12.new(application, get_url, nolinks)
    else
      app = RestApplication.new(application, get_url, nolinks)
    end
    include_cartridges = (params[:include] == "cartridges")
    if include_cartridges
      app.cartridges = get_cartridges(application)
    end
    render_success(:ok, "application", app, "SHOW_APPLICATION", "Application '#{id}' found")
  end
  
  # POST /domains/[domain_id]/applications
  def create
    domain_id = params[:domain_id]
    app_name = params[:name]
    cartridges = Array(params[:cartridges] || params[:cartridge])
    scale = get_bool(params[:scale])
    init_git_url = params[:initial_git_url]
    template_id = params[:template]
    node_profile = params[:gear_profile]
    node_profile.downcase! if node_profile
    
    domain = Domain.get(@cloud_user, domain_id)
    return render_error(:not_found, "Domain '#{domain_id}' not found", 127,
                        "ADD_APPLICATION") if !domain || !domain.hasAccess?(@cloud_user)
    
    @domain_name = domain.namespace
    return render_error(:unprocessable_entity, "Application name is required and cannot be blank",
                        105, "ADD_APPLICATION", "name") if !app_name or app_name.empty?

    application = get_application(app_name)
    return render_error(:unprocessable_entity, "The supplied application name '#{app_name}' already exists", 
                        100, "ADD_APPLICATION", "name") if application

    Rails.logger.debug "Checking to see if user limit for number of apps has been reached"
    return render_error(:unprocessable_entity, "#{@login} has already reached the gear limit of #{@cloud_user.max_gears}",
                        104, "ADD_APPLICATION") if (@cloud_user.consumed_gears >= @cloud_user.max_gears)
    
    application = nil
    if template_id
      template = ApplicationTemplate.find(template_id)
      return render_error(:unprocessable_entity, "Invalid template #{template_id}", 125,
                          "ADD_APPLICATION", "template") unless template
      application = Application.new(@cloud_user, app_name, nil, node_profile, nil, template, scale, domain)
    else
      framework_cartridges = []
      other_cartridges = []
      Rails.logger.debug "Selected cartridges: #{cartridges.inspect}"
      carts = get_cached("cart_list_standalone", :expires_in => 21600.seconds) {Application.get_available_cartridges("standalone")}
      if !cartridges
        
        return render_error(:unprocessable_entity, "You must specify a cartridge. Valid values are (#{carts.join(', ')})",
                            109, "ADD_APPLICATION", "cartridge")
      else
        cartridges.each do |cart|
          framework_cartridges.push(cart) unless not carts.include?(cart)
          other_cartridges.push(cart) unless carts.include?(cart)
        end
        if framework_cartridges.empty?
          return render_error(:unprocessable_entity, "Each application must contain one web cartridge.  None of the specified cartridges #{cartridges.to_sentence} is a web cartridge. Please include one of the following cartridges: #{carts.to_sentence}.",
                            109, "ADD_APPLICATION", "cartridge")
        elsif framework_cartridges.length > 1
          return render_error(:unprocessable_entity, "Each application must contain only one web cartridge.  Please include a single web cartridge from this list: #{carts.to_sentence}.",
                            109, "ADD_APPLICATION", "cartridge")
        end
      end
      begin
        application = Application.new(@cloud_user, app_name, nil, node_profile, framework_cartridges[0], nil, scale, domain, init_git_url)
      rescue Exception => e
        return render_error(:internal_server_error, "Error returned from server #{e.message}", 1, "ADD_APPLICATION")
      end
    end

    app_configure_reply = nil

    Rails.logger.debug "Validating application"  
    if not application.valid?
      messages = get_error_messages(application)
      return render_error(:unprocessable_entity, nil, nil, "ADD_APPLICATION", nil, nil, messages)
    end
 
    @application_name = application.name
    begin
      application.user_agent = request.headers['User-Agent']
      Rails.logger.debug "Creating application #{application.name}"
      application.create
      Rails.logger.debug "Configuring dependencies #{application.name}"
      app_configure_reply = application.configure_dependencies
      Rails.logger.debug "Executing connections for #{application.name}"
      application.execute_connections
      cart_reply = []
      other_cartridges.each do |cart|
        cart_reply << application.add_dependency(cart)
      end if other_cartridges and !other_cartridges.empty?
      begin
        Rails.logger.debug "Creating dns"
        application.create_dns
      rescue Exception => e
        log_action(@request_id, @cloud_user.uuid, @cloud_user.login, "ADD_APPLICATION", false, "Failed to create dns for application #{application.name}: #{e.message}", get_extra_log_args)
        application.destroy_dns
        raise
      end
    rescue Exception => e
      application.destroy(true)
      if application.persisted?
        application.delete
      end
      return render_exception(e, "ADD_APPLICATION") 
    end

    if $requested_api_version == 1.0
      app = RestApplication10.new(application, get_url, nolinks)
    elsif $requested_api_version < 1.3
      app = RestApplication12.new(application, get_url, nolinks)
    else
      app = RestApplication.new(application, get_url, nolinks)
    end
    messages = []
    log_msg = "Application #{application.name} was created."
    messages.push(Message.new(:info, log_msg))

    current_ip = application.get_public_ip_address
    messages.push(Message.new(:info, "#{current_ip}", 0, "current_ip")) unless !current_ip or current_ip.empty?
    messages.push(Message.new(:info, app_configure_reply.resultIO.string, 0, :result)) if app_configure_reply
    cart_reply.each do |reply|
      messages.push(Message.new(:info, reply.resultIO.string, 0, :result))
    end unless cart_reply.empty?
    include_cartridges = (params[:include] == "cartridges")
    if include_cartridges
      app.cartridges = get_cartridges(application)
    end
    render_success(:created, "application", app, "ADD_APPLICATION", log_msg, nil, nil, messages) 
  end
  
  # DELELTE domains/[domain_id]/applications/[id]
  def destroy
    domain_id = params[:domain_id]
    id = params[:id]
    
    domain = Domain.get(@cloud_user, domain_id)
    return render_format_error(:not_found, "Domain #{domain_id} not found", 127,
                               "DELETE_APPLICATION") if !domain || !domain.hasAccess?(@cloud_user)
    
    @domain_name = domain.namespace
    application = get_application(id)
    return render_format_error(:not_found, "Application #{id} not found.", 101,
                               "DELETE_APPLICATION") if !application or application.domain.uuid != domain.uuid
    
    @application_name = application.name
    @application_uuid = application.uuid
    begin
      Rails.logger.debug "Deleting application #{id}"
      application.cleanup_and_delete()
    rescue Exception => e
      return render_format_exception(e, "DELETE_APPLICATION")
    end
    render_format_success(:no_content, nil, nil, "DELETE_APPLICATION", "Application #{id} is deleted.", true) 
  end
end
