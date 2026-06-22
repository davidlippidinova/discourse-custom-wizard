# frozen_string_literal: true
class CustomWizard::Action
  attr_accessor :submission, :action, :user, :guardian, :result

  REQUIRES_USER = %w[update_profile open_composer watch_categories add_to_group]

  WIZARD_USER = "wizard-user"

  def initialize(opts)
    @wizard = opts[:wizard]
    @action = opts[:action]
    @user = @wizard.user
    @guardian = Guardian.new(@user)
    @submission = opts[:submission]
    @log = []
    @result = CustomWizard::ActionResult.new
  end

  def perform
    if REQUIRES_USER.include?(action["id"]) && !@user
      log_error("action requires user", "id: #{action["id"]};")
      @result.success = false
      return @result
    end

    ActiveRecord::Base.transaction { self.send(action["type"].to_sym) }

    @result.handler.enqueue_jobs if creates_post? && @result.success? && @result.handler.respond_to?(:enqueue_jobs)

    @submission.fields[action["id"]] = @result.output if @result.success? && @result.output.present?

    save_log

    @result.submission = @submission
    @result
  end

  def mapper_data
    @mapper_data ||= @submission&.fields_and_meta || {}
  end

  def mapper
    @mapper ||= CustomWizard::Mapper.new(user: user, data: mapper_data)
  end

  def callbacks_for(action)
    self.class.callbacks[action] || []
  end

  def create_topic
    params = basic_topic_params.merge(public_topic_params)

    callbacks_for(:before_create_topic).each do |acb|
      params = acb.call(params, @wizard, @action, @submission)
    end

    unless params[:title].present? && params[:raw].present?
      log_error("invalid topic params", "title: #{params[:title]}; post: #{params[:raw]}")
      return
    end

    poster = topic_poster
    target_category = params[:category] && Category.find_by(id: params[:category])

    if topic_needs_review?(poster, target_category)
      enqueue_topic_for_review(poster, params, target_category)
    else
      creator = PostCreator.new(poster, params)
      post = creator.create

      if creator.errors.present?
        messages = creator.errors.full_messages.join(" ")
        log_error("failed to create", messages)
      elsif action["skip_redirect"].blank?
        @submission.redirect_on_complete = post.topic.url
      end

      if creator.errors.blank?
        log_success("created topic", "id: #{post.topic.id}")
        result.handler = creator
        result.output = post.topic.id
      end
    end
  end

  def send_message
    if action["required"].present?
      required =
        CustomWizard::Mapper.new(inputs: action["required"], data: mapper_data, user: user).perform

      if required.blank?
        log_error("required input not present")
        return
      end
    end

    params = basic_topic_params

    targets =
      CustomWizard::Mapper.new(
        inputs: action["recipient"],
        data: mapper_data,
        user: user,
        multiple: true,
      ).perform

    if targets.blank?
      log_error("no recipients", "send_message has no recipients")
      return
    end

    params[:target_group_names] = []
    params[:target_usernames] = []
    params[:target_emails] = []
    [*targets].each do |target|
      if Group.find_by(name: target)
        params[:target_group_names] << target
      elsif User.find_by_username(target)
        params[:target_usernames] << target
      elsif target.match(/@/) # Compare discourse/discourse/app/controllers/posts_controller.rb#L922-L923
        params[:target_emails] << target
      end
    end

    if params[:title].present? && params[:raw].present? &&
         (
           params[:target_usernames].present? || params[:target_group_names].present? ||
             params[:target_emails].present?
         )
      params[:archetype] = Archetype.private_message

      creator = PostCreator.new(topic_poster, params)
      post = creator.create

      if creator.errors.present?
        messages = creator.errors.full_messages.join(" ")
        log_error("failed to create message", messages)
      elsif user && action["skip_redirect"].blank?
        @submission.redirect_on_complete = post.topic.url
      end

      if creator.errors.blank?
        log_success("created message", "id: #{post.topic.id}")
        result.handler = creator
        result.output = post.topic.id
      end
    else
      log_error(
        "invalid message params",
        "title: #{params[:title]}; post: #{params[:raw]}; recipients: #{params[:target_usernames]}",
      )
    end
  end

  def update_profile
    params = {}

    if (profile_updates = action["profile_updates"])
      profile_updates.first[:pairs].each do |pair|
        if allowed_profile_field?(pair["key"])
          key = cast_profile_key(pair["key"])
          value =
            cast_profile_value(mapper.map_field(pair["value"], pair["value_type"]), pair["key"])

          if user_field?(pair["key"])
            params[:custom_fields] ||= {}
            params[:custom_fields][key] = value
          else
            params[key.to_sym] = value
          end
        end
      end
    end

    params = add_custom_fields(params)

    if params.present?
      result = UserUpdater.new(Discourse.system_user, user).update(params)

      result = update_avatar(params[:avatar]) if params[:avatar].present?

      if result
        log_success("updated profile fields", "fields: #{params.keys.map(&:to_s).join(",")}")
      else
        log_error("failed to update profile fields", "result: #{result.inspect}")
      end
    else
      log_error("invalid profile fields params", "params: #{params.inspect}")
    end
  end

  def watch_tags
    tags = CustomWizard::Mapper.new(inputs: action["tags"], data: mapper_data, user: user).perform

    tags = [*tags]
    level = action["notification_level"].to_sym

    if level.blank?
      log_error("Notifcation Level was not set. Exiting watch tags action")
      return
    end

    users = []

    if action["usernames"]
      mapped_users =
        CustomWizard::Mapper.new(inputs: action["usernames"], data: mapper_data, user: user).perform

      if mapped_users.present?
        mapped_users = mapped_users.split(",").map { |username| User.find_by(username: username) }
        users.push(*mapped_users)
      end
    end

    users.push(user) if ActiveRecord::Type::Boolean.new.cast(action["wizard_user"])

    users.each do |user|
      result = TagUser.batch_set(user, level, tags)

      if result
        log_success("#{user.username} notifications for #{tags} set to #{level}")
      else
        log_error("failed to set #{user.username} notifications for #{tags} to #{level}")
      end
    end
  end

  def watch_categories
    watched_categories =
      CustomWizard::Mapper.new(inputs: action["categories"], data: mapper_data, user: user).perform

    watched_categories = [*watched_categories].map(&:to_i)

    notification_level = action["notification_level"]

    if notification_level.blank?
      log_error("Notifcation Level was not set. Exiting wizard action")
      return
    end

    mute_remainder =
      CustomWizard::Mapper.new(
        inputs: action["mute_remainder"],
        data: mapper_data,
        user: user,
      ).perform

    users = []

    if action["usernames"]
      mapped_users =
        CustomWizard::Mapper.new(inputs: action["usernames"], data: mapper_data, user: user).perform

      if mapped_users.present?
        mapped_users = mapped_users.split(",").map { |username| User.find_by(username: username) }
        users.push(*mapped_users)
      end
    end

    users.push(user) if ActiveRecord::Type::Boolean.new.cast(action["wizard_user"])

    category_ids = Category.all.pluck(:id)
    set_level = CategoryUser.notification_levels[notification_level.to_sym]
    mute_level = CategoryUser.notification_levels[:muted]

    users.each do |user|
      category_ids.each do |category_id|
        new_level = nil

        if watched_categories.include?(category_id) && set_level != nil
          new_level = set_level
        elsif mute_remainder
          new_level = mute_level
        end

        CategoryUser.set_notification_level_for_category(user, new_level, category_id) if new_level
      end

      if watched_categories.any?
        log_success("#{user.username} notifications for #{watched_categories} set to #{set_level}")
      end

      log_success("#{user.username} notifications for all other categories muted") if mute_remainder
    end
  end

  def send_to_api
    api_body = nil

    if action["api_body"] != ""
      begin
        api_body_parsed = JSON.parse(action["api_body"])
      rescue JSON::ParserError
        raise Discourse::InvalidParameters,
              "Invalid API body definition: #{action["api_body"]} for #{action["title"]}"
      end
      api_body = JSON.parse(mapper.interpolate(JSON.generate(api_body_parsed)))
    end

    result =
      CustomWizard::Api::Endpoint.request(user, action["api"], action["api_endpoint"], api_body)

    if error = result["error"] || (result[0] && result[0]["error"])
      error = error["message"] || error
      log_error("api request failed", "message: #{error}")
    else
      log_success("api request succeeded", "result: #{result}")
    end
  end

  def open_composer
    params = basic_topic_params

    if params[:title].present? && params[:raw].present?
      url = "/new-topic?title=#{encode_query_param(params[:title])}"
      url += "&body=#{encode_query_param(params[:raw])}"

      if category_id = action_category
        url += "&category_id=#{category_id}"
      end

      if tags = action_tags
        url += "&tags=#{tags.join(",")}"
      end

      route_to = Discourse.base_uri + url
      @result.output = @submission.route_to = route_to

      log_success("route: #{route_to}")
    else
      log_error("invalid composer params", "title: #{params[:title]}; post: #{params[:raw]}")
    end
  end

  def add_to_group
    group_map =
      CustomWizard::Mapper.new(
        inputs: action["group"],
        data: mapper_data,
        user: user,
        opts: {
          multiple: true,
        },
      ).perform

    group_map = group_map.flatten.compact

    if group_map.blank?
      log_error("invalid group map")
      return
    end

    groups =
      group_map.reduce([]) do |result, g|
        begin
          result.push(Integer(g))
        rescue ArgumentError
          group = Group.find_by(name: g)
          result.push(group.id) if group
        end

        result
      end

    result = nil

    if groups.present?
      groups.each do |group_id|
        group = Group.find_by(id: group_id) if group_id
        result = group.add(user) if group
      end
    end

    if result
      log_success("added to groups", "groups: #{groups.map(&:to_s).join(",")}")
    else
      detail = groups.present? ? "groups: #{groups.map(&:to_s).join(",")}" : nil
      log_error("failed to add to groups", detail)
    end
  end

  def route_to
    return if (url_input = action["url"]).blank?

    if url_input.is_a?(String)
      url = mapper.interpolate(url_input)
    else
      url = CustomWizard::Mapper.new(inputs: url_input, data: mapper_data, user: user).perform
    end

    if action["code"].present?
      @submission.fields[action["code"]] = SecureRandom.hex(8)
      url += "&#{action["code"]}=#{@submission.fields[action["code"]]}"
    end

    route_to = UrlHelper.encode(url)
    @submission.route_to = route_to

    log_info("route: #{route_to}")
  end

  def create_group
    group =
      begin
        Group.new(new_group_params.except(:usernames, :owner_usernames))
      rescue ArgumentError => e
        raise Discourse::InvalidParameters, "Invalid group params"
      end

    if group.save
      def get_user_ids(username_string)
        User.where(username: username_string.split(",")).pluck(:id)
      end

      if new_group_params[:owner_usernames].present?
        owner_ids = get_user_ids(new_group_params[:owner_usernames])
        owner_ids.each { |user_id| group.group_users.build(user_id: user_id, owner: true) }
      end

      if new_group_params[:usernames].present?
        user_ids = get_user_ids(new_group_params[:usernames])
        if user_ids.count < new_group_params[:usernames].count
          log_error("Warning, group creation: some users were not found!")
        end
        user_ids -= owner_ids if owner_ids
        user_ids.each { |user_id| group.group_users.build(user_id: user_id) }
      end

      log_success("Group created", group.name) if group.save

      result.output = group.name
    else
      log_error("Group creation failed", group.errors.messages)
    end
  end

  def create_category
    category =
      begin
        Category.new(new_category_params.merge(user: user))
      rescue ArgumentError => e
        raise Discourse::InvalidParameters, "Invalid category params"
      end

    if category.save
      StaffActionLogger.new(user).log_category_creation(category)
      log_success("Category created", category.name)
      result.output = category.id
    else
      log_error("Category creation failed", category.errors.messages)
    end
  end

  def self.callbacks
    @callbacks ||= {}
  end

  def self.register_callback(action, &block)
    callbacks[action] ||= []
    callbacks[action] << block
  end

  private

  def action_category
    output =
      CustomWizard::Mapper.new(inputs: action["category"], data: mapper_data, user: user).perform

    return false if output.blank?

    if output.is_a?(Array)
      output.first
    elsif output.is_a?(Integer)
      output
    elsif output.is_a?(String)
      output.to_i
    end
  end

  def action_tags
    output = CustomWizard::Mapper.new(inputs: action["tags"], data: mapper_data, user: user).perform

    return false if output.blank?

    if output.is_a?(Array)
      output.flatten
    else
      output.is_a?(String)
      [*output]
    end
  end

  def add_custom_fields(params = {})
    if (custom_fields = action["custom_fields"]).present?
      field_map =
        CustomWizard::Mapper.new(inputs: custom_fields, data: mapper_data, user: user).perform
      registered_fields = CustomWizard::CustomField.full_list

      field_map.each do |field|
        keyArr = field[:key].split(".")
        value = field[:value]

        if keyArr.length > 1
          klass = keyArr.first.to_sym
          name = keyArr.second

          if keyArr.length === 3 && name.include?("{}")
            name = name.gsub("{}", "")
            json_attr = keyArr.last
            type = :json
          end
        else
          name = keyArr.first
        end

        registered = registered_fields.select { |f| f.name == name }.first
        if registered.present?
          klass = registered.klass.to_sym
          type = registered.type.to_sym
        end

        next if type === :json && json_attr.blank?

        if klass === :topic
          params[:topic_opts] ||= {}
          params[:topic_opts][:custom_fields] ||= {}

          if type === :json
            params[:topic_opts][:custom_fields][name] ||= {}
            params[:topic_opts][:custom_fields][name][json_attr] = value
          else
            params[:topic_opts][:custom_fields][name] = value
          end
        else
          if type === :json
            params[:custom_fields][name] ||= {}
            params[:custom_fields][name][json_attr] = value
          else
            params[:custom_fields] ||= {}
            params[:custom_fields][name] = value
          end
        end
      end
    end

    params
  end

  def basic_topic_params
    params = {
      skip_validations: true,
      topic_opts: {
        custom_fields: {
          wizard_submission_id: @wizard.current_submission.id,
        },
      },
    }

    params[:title] = CustomWizard::Mapper.new(
      inputs: action["title"],
      data: mapper_data,
      user: user,
    ).perform

    params[:raw] = (
      if action["post_builder"]
        mapper.interpolate(
          action["post_template"],
          user: true,
          value: true,
          wizard: true,
          template: true,
        )
      else
        @submission.fields[action["post"]]
      end
    )

    params[:import_mode] = ActiveRecord::Type::Boolean.new.cast(action["suppress_notifications"])

    add_custom_fields(params)
  end

  def public_topic_params
    params = {}

    if category = action_category
      params[:category] = category
    end

    if tags = action_tags
      params[:tags] = tags
    end

    if public_topic_fields.any?
      public_topic_fields.each do |field|
        unless action[field].nil? || action[field] == ""
          params[field.to_sym] = CustomWizard::Mapper.new(
            inputs: action[field],
            data: mapper_data,
            user: user,
          ).perform
        end
      end
    end

    params
  end

  def topic_poster
    @topic_poster ||=
      begin
        poster_id =
          CustomWizard::Mapper.new(inputs: action["poster"], data: mapper_data, user: user).perform
        poster_id = [*poster_id].first if poster_id.present?

        if poster_id.blank? || poster_id === WIZARD_USER
          poster = user || guest_user
        else
          poster = User.find_by_username(poster_id)
        end

        poster || Discourse.system_user
      end
  end

  def guest_user
    @guest_user ||=
      begin
        return nil unless action["guest_email"]

        email = CustomWizard::Mapper.new(inputs: action["guest_email"], data: mapper_data).perform

        if email&.match(/@/)
          if user = User.find_by_email(email)
            user
          else
            User.create!(
              email: email,
              username: UserNameSuggester.suggest(email),
              name: User.suggest_name(email),
              staged: true,
            )
          end
        end
      end
  end

  def new_group_params
    params = {}

    %w[
      name
      full_name
      title
      bio_raw
      owner_usernames
      usernames
      mentionable_level
      messageable_level
      visibility_level
      members_visibility_level
      grant_trust_level
    ].each do |attr|
      input = action[attr]

      raise ArgumentError.new if attr === "name" && input.blank?

      input = action["name"] if attr === "full_name" && input.blank?

      if input.present?
        value = CustomWizard::Mapper.new(inputs: input, data: mapper_data, user: user).perform

        if value
          value = value.parameterize(separator: "_") if attr === "name"
          value = value.to_i if attr.include?("_level")

          params[attr.to_sym] = value
        end
      end
    end

    add_custom_fields(params)
  end

  def new_category_params
    params = {}

    %w[name slug color text_color parent_category_id permissions].each do |attr|
      if action[attr].present?
        value =
          CustomWizard::Mapper.new(inputs: action[attr], data: mapper_data, user: user).perform

        if value
          value = value[0] if attr === "parent_category_id" && value.is_a?(Array)

          if attr === "permissions" && value.is_a?(Array)
            permissions = value
            value = {}

            permissions.each do |p|
              k = p[:key]
              v = p[:value].to_i

              if k.is_a?(Array)
                group = Group.find_by(id: k[0])
                k = group.name
              else
                k = k.parameterize(separator: "_")
              end

              value[k] = v
            end
          end

          value = value.parameterize(separator: "-") if attr === "slug"

          params[attr.to_sym] = value
        end
      end
    end

    add_custom_fields(params)
  end

  def creates_post?
    %i[create_topic send_message].include?(action["type"].to_sym)
  end

  def topic_needs_review?(poster, category)
    return false if poster.blank? || poster.staff?

    if category &&
         category.respond_to?(:require_topic_approval?) &&
         category.require_topic_approval?
      return true
    end

    if SiteSetting.respond_to?(:approve_new_topics_unless_allowed_groups)
      allowed_ids =
        SiteSetting
          .approve_new_topics_unless_allowed_groups
          .to_s
          .split("|")
          .map(&:to_i)
          .reject(&:zero?)
      if allowed_ids.any? && poster.respond_to?(:in_any_groups?) &&
           !poster.in_any_groups?(allowed_ids)
        return true
      end
    end

    if SiteSetting.respond_to?(:approve_post_count) &&
         SiteSetting.approve_post_count.to_i > 0 &&
         poster.trust_level == TrustLevel[0] &&
         poster.post_count.to_i < SiteSetting.approve_post_count.to_i
      return true
    end

    false
  end

  def enqueue_topic_for_review(poster, params, category)
    payload = {
      raw: params[:raw],
      title: params[:title],
      archetype: Archetype.default,
      category: category&.id,
      tags: params[:tags],
    }

    topic_custom_fields = params.dig(:topic_opts, :custom_fields)
    payload[:custom_fields] = topic_custom_fields if topic_custom_fields.present?

    reviewable_attrs = {
      payload: payload.compact,
      category_id: category&.id,
      reviewable_by_moderator: true,
    }

    # Recent Discourse versions expect `created_by` to be the system user
    # and `target_created_by` to be the real author. Fallback for older
    # Discourse versions where the column does not exist.
    if ReviewableQueuedPost.column_names.include?("target_created_by_id")
      reviewable_attrs[:created_by] = Discourse.system_user
      reviewable_attrs[:target_created_by] = poster
    else
      reviewable_attrs[:created_by] = poster
    end

    reviewable = ReviewableQueuedPost.new(reviewable_attrs)

    if reviewable.save
      if reviewable.respond_to?(:create_score) &&
           !reviewable.reviewable_scores.exists?
        begin
          reviewable.create_score(Discourse.system_user, :needs_approval)
        rescue StandardError
          # create_score signature varies between Discourse versions; ignore
          # if it fails so the reviewable is still created.
        end
      end
      log_success("topic queued for review", "reviewable_id: #{reviewable.id}")
      # Topic isn't published yet, so do not redirect to a topic URL.
      result.output = nil
      result.success = true
    else
      log_error(
        "failed to queue topic for review",
        reviewable.errors.full_messages.join(" "),
      )
    end
  end

  def public_topic_fields
    ["visible"]
  end

  def profile_url_fields
    %w[profile_background card_background]
  end

  def cast_profile_key(key)
    if profile_url_fields.include?(key)
      "#{key}_upload_url"
    else
      key
    end
  end

  def cast_profile_value(value, key)
    return value if value.nil?

    if profile_url_fields.include?(key)
      value["url"]
    elsif key === "avatar"
      value["id"]
    else
      value
    end
  end

  def profile_excluded_fields
    %w[username email trust_level].freeze
  end

  def allowed_profile_field?(field)
    allowed_profile_fields.include?(field) || user_field?(field)
  end

  def user_field?(field)
    field.to_s.include?(::User::USER_FIELD_PREFIX) &&
      ::UserField.exists?(field.split("_").last.to_i)
  end

  def allowed_profile_fields
    CustomWizard::Mapper.user_fields.select { |f| profile_excluded_fields.exclude?(f) } +
      profile_url_fields + ["avatar"]
  end

  def update_avatar(upload_id)
    user.create_user_avatar unless user.user_avatar
    user.user_avatar.custom_upload_id = upload_id
    user.uploaded_avatar_id = upload_id
    user.save!
    user.user_avatar.save!
  end

  def encode_query_param(param)
    Addressable::URI.encode_component(param, Addressable::URI::CharacterClasses::UNRESERVED)
  end

  def log_success(message, detail = nil)
    @log.push("success: #{message} - #{detail}")
    @result.success = true
  end

  def log_error(message, detail = nil)
    @log.push("error: #{message} - #{detail}")
    @result.success = false
  end

  def log_info(message, detail = nil)
    @log.push("info: #{message} - #{detail}")
  end

  def save_log
    username = user ? user.username : @wizard.actor_id

    CustomWizard::Log.create(@wizard.id, action["type"], username, @log.join("; "))
  end
end
