# frozen_string_literal: true

#
# Copyright (C) 2011 - present Instructure, Inc.
#
# This file is part of Canvas.
#
# Canvas is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, version 3 of the License.
#
# Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
# details.
#
# You should have received a copy of the GNU Affero General Public License along
# with this program. If not, see <http://www.gnu.org/licenses/>.
#
class ImpossibleCredentialsError < ArgumentError; end

class Pseudonym < ActiveRecord::Base
  include Workflow

  has_many :session_persistence_tokens
  belongs_to :account
  include Canvas::RootAccountCacher
  belongs_to :user
  has_many :communication_channels, -> { ordered }
  has_many :sis_enrollments, class_name: 'Enrollment', inverse_of: :sis_pseudonym
  has_many :auditor_authentication_records,
    class_name: "Auditors::ActiveRecord::AuthenticationRecord",
    dependent: :destroy,
    inverse_of: :pseudonym
  belongs_to :communication_channel
  belongs_to :sis_communication_channel, :class_name => 'CommunicationChannel'
  belongs_to :authentication_provider
  MAX_UNIQUE_ID_LENGTH = 100

  CAS_TICKET_TTL = 1.day

  validates_length_of :unique_id, :maximum => MAX_UNIQUE_ID_LENGTH
  validates_length_of :sis_user_id, :maximum => maximum_string_length, :allow_blank => true
  validates_presence_of :account_id
  validate :must_be_root_account
  # allows us to validate the user and pseudonym together, before saving either
  validates_each :user_id do |record, attr, value|
    record.errors.add(attr, "blank?") unless value || record.user
  end
  before_validation :validate_unique_id
  before_destroy :retire_channels

  before_save :set_password_changed
  before_validation :infer_defaults, :verify_unique_sis_user_id, :verify_unique_integration_id
  after_save :update_account_associations_if_account_changed
  has_a_broadcast_policy

  alias_attribute :root_account_id, :account_id

  alias_method :context, :account

  include StickySisFields
  are_sis_sticky :unique_id

  validates :unique_id, format: { with: /\A[[:print:]]+\z/ },
            length: { within: 1..MAX_UNIQUE_ID_LENGTH },
            uniqueness: {
              case_sensitive: false,
              scope: [:account_id, :workflow_state, :authentication_provider_id],
              if: ->(p) { (p.unique_id_changed? || p.workflow_state_changed?) && p.active? }
            }

  validates :password,
            confirmation: true,
            if: :require_password?

  validates_each :password, if: :require_password?,
            &Canvas::PasswordPolicy.method("validate")
  validates :password_confirmation,
            presence: true,
            if: :require_password?

  acts_as_authentic do |config|
    config.login_field :unique_id
    config.perishable_token_valid_for = 30.minutes
    # if changing this to a new provider, add the _new_ provider to the transition
    # list for a full deploy first before moving it to primary, so that
    # a) there won't be any possibility of split brain where old-still-running code
    #   can't understand the new hash in the db from new code, and
    # b) if we have to roll back to old code, users won't be locked out
    config.crypto_provider = ScryptProvider.new("4000$8$1$")
    config.transition_from_crypto_providers = [Authlogic::CryptoProviders::Sha512]
  end

  attr_writer :require_password
  def require_password?
    # Change from auth_logic: don't require a password just because new_record?
    # is true. just check if the pw has changed or crypted_password_field is
    # blank.
    password_changed? || (send(crypted_password_field).blank? && sis_ssha.blank?) || @require_password
  end

  acts_as_list :scope => :user

  set_broadcast_policy do |p|
    p.dispatch :confirm_registration
    p.to { self.communication_channel || self.user.communication_channel }
    p.whenever { |record|
      @send_confirmation
    }

    p.dispatch :pseudonym_registration
    p.to { self.communication_channel || self.user.communication_channel }
    p.whenever { @send_registration_notification }

    p.dispatch :pseudonym_registration_done
    p.to { self.communication_channel || self.user.communication_channel }
    p.whenever { @send_registration_done_notification }
  end

  def update_account_associations_if_account_changed
    return unless self.user && !User.skip_updating_account_associations?
    if self.id_before_last_save.nil?
      return if %w{creation_pending deleted}.include?(self.user.workflow_state)
      self.user.update_account_associations(:incremental => true, :precalculated_associations => {self.account_id => 0})
    elsif self.saved_change_to_account_id?
      self.user.update_account_associations_later
    end
  end

  def must_be_root_account
    if account_id_changed?
      self.errors.add(:account_id, "must belong to a root_account") unless account.root_account?
    end
  end

  def send_registration_notification!
    @send_registration_notification = true
    self.save!
    @send_registration_notification = false
  end

  def send_registration_done_notification!
    @send_registration_done_notification = true
    self.save!
    @send_registration_done_notification = false
  end

  def send_confirmation!
    @send_confirmation = true
    self.save!
    @send_confirmation = false
  end

  scope :by_unique_id, lambda {|unique_id| where("LOWER(unique_id)=LOWER(?)", unique_id.to_s)}

  def self.custom_find_by_unique_id(unique_id)
    return unless unique_id
    active.by_unique_id(unique_id).where("authentication_provider_id IS NULL OR EXISTS (?)",
      AuthenticationProvider.active.where(auth_type: ['canvas', 'ldap']).
        where("authentication_provider_id=authentication_providers.id")).first
  end

  def self.for_auth_configuration(unique_id, aac)
    auth_id = aac.try(:auth_provider_filter)
    active.by_unique_id(unique_id).where(authentication_provider_id: auth_id).
      order("authentication_provider_id NULLS LAST").take
  end

  def set_password_changed
    @password_changed = self.password && self.password_confirmation == self.password
  end

  def password=(new_pass)
    self.password_auto_generated = false
    super(new_pass)
  end

  def communication_channel
    self.user.communication_channels.by_path(self.unique_id).first
  end

  def confirmation_code
    (self.communication_channel || self.user.communication_channel).confirmation_code
  end

  def infer_defaults
    self.account ||= Account.default
    if (!crypted_password || crypted_password == "") && !@require_password
      self.generate_temporary_password
    end
    # treat empty or whitespaced strings as nullable
    self.integration_id = nil if self.integration_id.blank?
    self.sis_user_id = nil if self.sis_user_id.blank?
  end

  def login_assertions_for_user
    if !self.persistence_token || self.persistence_token == ''
      # Some pseudonyms can end up without a persistence token if they were created
      # using the SIS, for example.
      self.persistence_token = CanvasSlug.generate('pseudo', 15)
      self.save
    end

    user = self.user
    user.workflow_state = 'registered' unless user.registered?

    add_ldap_channel

    # Assert a time zone for the user if none provided
    if user && !user.time_zone
      user.time_zone = self.account.default_time_zone rescue Account.default.default_time_zone
      user.time_zone ||= Time.zone
    end
    user.save if user.workflow_state_changed? || user.time_zone_changed?
    user
  end

  def authentication_type
    :email_login
  end

  def works_for_account?(account, allow_implicit = false, ignore_types: [:implicit])
    true
  end

  def <=>(other)
    self.position <=> other.position
  end

  def retire_channels
    communication_channels.each{|cc| cc.update_attribute(:workflow_state, 'retired') }
  end

  def validate_unique_id
    if (!self.account || self.account.email_pseudonyms) && !self.deleted?
      unless self.unique_id.present? && EmailAddressValidator.valid?(self.unique_id)
        self.errors.add(:unique_id, "not_email")
        throw :abort
      end
    end
    unless self.deleted?
      self.shard.activate do
        existing_pseudo = Pseudonym.active.by_unique_id(self.unique_id).where(:account_id => self.account_id,
          :authentication_provider_id => self.authentication_provider_id).where.not(id: self).exists?
        if existing_pseudo
          self.errors.add(:unique_id, :taken,
            message: t("ID already in use for this account and authentication provider"))
          throw :abort
        end
      end
    end
    true
  end

  def verify_unique_sis_user_id
    return true unless self.sis_user_id
    return true unless Pseudonym.where.not(id: id).where(account_id: self.account_id, sis_user_id: self.sis_user_id).exists?
    self.errors.add(:sis_user_id, :taken,
      message: t('#errors.sis_id_in_use', "SIS ID \"%{sis_id}\" is already in use", sis_id: self.sis_user_id))
    throw :abort
  end

  def verify_unique_integration_id
    return true unless self.integration_id
    return true unless Pseudonym.where.not(id: id).where(account_id: self.account_id, integration_id: self.integration_id).exists?
    self.errors.add(:integration_id, :taken,
      message: t("Integration ID \"%{integration_id}\" is already in use", integration_id: self.integration_id))
    throw :abort
  end

  workflow do
    state :active
    state :deleted
  end

  set_policy do
    # an admin can only create and update pseudonyms when they have
    # :manage_user_logins permission on the pseudonym's account, :read
    # permission on the pseudonym's owner, and a superset of the pseudonym's
    # owner's rights (if any) on the pseudonym's account. some fields of the
    # pseudonym may require additional conditions to update (see below)
    given do |user|
      self.account.grants_right?(user, :manage_user_logins) &&
      self.user.has_subset_of_account_permissions?(user, self.account) &&
      self.user.grants_right?(user, :read)
    end
    can :create and can :update

    # any user (admin or not) can change their own canvas password. if the
    # pseudonym's account does not allow canvas authentication (i.e. it uses
    # and requires delegated authentication), there is no canvas password to
    # change.
    given do |user|
      user_id == user.try(:id) &&
      passwordable?
    end
    can :change_password

    # an admin can set the initial canvas password (if there is one, see above)
    # on another user's new pseudonym.
    given do |user|
      new_record? &&
      passwordable? &&
      grants_right?(user, :create)
    end
    can :change_password

    # an admin can only change another user's canvas password (if there is one,
    # see above) on an existing pseudonym when :admins_can_change_passwords is
    # enabled.
    given do |user|
      account.settings[:admins_can_change_passwords] &&
      passwordable? &&
      grants_right?(user, :update)
    end
    can :change_password

    # an admin can only update a pseudonym's SIS ID when they have :manage_sis
    # permission on the pseudonym's account
    given do |user|
      self.account.grants_right?(user, :manage_sis) &&
      self.grants_right?(user, :update)
    end
    can :manage_sis

    # an admin can delete any non-SIS pseudonym that they can update
    given do |user|
      !sis_user_id && grants_right?(user, :update)
    end
    can :delete

    # an admin can only delete an SIS pseudonym if they also can :manage_sis
    given do |user|
      sis_user_id && grants_right?(user, :manage_sis)
    end
    can :delete
  end

  alias_method :destroy_permanently!, :destroy
  def destroy
    self.workflow_state = 'deleted'
    self.deleted_at = Time.now.utc
    result = self.save
    self.user.try(:update_account_associations) if result
    result
  end

  def never_logged_in?
    !self.login_count || self.login_count == 0
  end

  def user_code
    self.user.uuid rescue nil
  end

  def email
    user.email if user
  end

  def email_channel
    self.communication_channel if self.communication_channel && self.communication_channel.path_type == 'email'
  end

  def email=(e)
    return false unless user
    self.user.email=(e)
    user.save!
    user.email
  end

  def sms
    user.sms if user
  end

  def sms=(s)
    return false unless user
    self.user.sms=(s)
    user.save!
    user.sms
  end

  def infer_auth_provider(ap)
    previously_changed = changed?
    self.authentication_provider ||= ap
    save! if !previously_changed && changed? && account.feature_enabled?(:persist_inferred_authentication_providers)
  end

  # managed_password? and passwordable? differ in their treatment of pseudonyms
  # not linked to an authentication_provider. They both err towards the
  # "positive" case matching their name. I.e. if you have both Canvas and
  # non-Canvas auth configured, they'll both return true for a pseudonym with an
  # SIS ID not explicitly linked to an authentication provider.
  def managed_password?
    if authentication_provider
      # explicit provider we can be sure if it's managed or not
      !authentication_provider.is_a?(AuthenticationProvider::Canvas)
    else
      # otherwise we have to guess
      !!(self.sis_user_id && account.non_canvas_auth_configured?)
    end
  end

  def passwordable?
    authentication_provider.is_a?(AuthenticationProvider::Canvas) ||
      (!authentication_provider && account.canvas_authentication?)
  end

  def valid_arbitrary_credentials?(plaintext_password)
    return false if self.deleted?
    return false if plaintext_password.blank?
    require 'net/ldap'
    res = false
    res ||= valid_ldap_credentials?(plaintext_password)
    if !res && passwordable?
      # Only check SIS if they haven't changed their password
      res = valid_ssha?(plaintext_password) if password_auto_generated?
      res ||= valid_password?(plaintext_password)
      infer_auth_provider(account.canvas_authentication_provider) if res
    end
    res
  end

  def generate_temporary_password
    self.reset_password
    self.password_auto_generated = true
    self.password
  end

  def valid_ssha?(plaintext_password)
    return false if plaintext_password.blank? || self.sis_ssha.blank?
    decoded = Base64::decode64(self.sis_ssha.sub(/\A\{SSHA\}/, ""))
    digest = decoded[0,40]
    salt = decoded[40..-1]
    return false unless digest && salt
    digested_password = Digest::SHA1.digest(plaintext_password + salt).unpack('H*').first
    digest == digested_password
  end

  def ldap_bind_result(password_plaintext)
    aps = case authentication_provider
          when AuthenticationProvider::LDAP
            [authentication_provider]
          when nil
            account.authentication_providers.active.where(auth_type: 'ldap')
          # when AuthenticationProvider::Canvas
          else
            []
    end
    aps.each do |config|
      res = config.ldap_bind_result(self.unique_id, password_plaintext)
      next unless res

      infer_auth_provider(config)
      return res
    end
    nil
  end

  def add_ldap_channel
    return nil unless managed_password?
    res = @ldap_result
    if res && res[:mail] && res[:mail][0]
      email = res[:mail][0]
      cc = self.user.communication_channels.email.by_path(email).first
      cc ||= self.user.communication_channels.build(:path => email)
      cc.workflow_state = 'active'
      cc.user = self.user
      cc.save if cc.changed?
      self.communication_channel = cc
      self.save_without_session_maintenance if self.changed?
    end
  end

  attr_reader :ldap_result
  def valid_ldap_credentials?(password_plaintext)
    return false if password_plaintext.blank?
    # try to authenticate against the LDAP server
    res = ldap_bind_result(password_plaintext)
    if res
      @ldap_result = res[0]
    end
    !!res
  rescue => e
    Canvas::Errors.capture(e, {
      type: :ldap,
      message: "LDAP authentication error",
      object: self.inspect.to_s,
      unique_id: self.unique_id,
    })
    nil
  end

  scope :active, -> { where(workflow_state: 'active') }

  def self.serialization_excludes; [:crypted_password, :password_salt, :reset_password_token, :persistence_token, :single_access_token, :perishable_token, :sis_ssha]; end

  def self.associated_shards(unique_id_or_sis_user_id)
    [Shard.default]
  end

  def self.find_all_by_arbitrary_credentials(credentials, account_ids, remote_ip)
    return [] if credentials[:unique_id].blank? ||
                 credentials[:password].blank?
    if credentials[:unique_id].length > 255
      # this sometimes happens by mistake, and produces noisy errors.
      # we can handle this error explicitly when it arrives and just return
      # a failed login instead of an error.
      raise ImpossibleCredentialsError, "pseudonym cannot have a unique_id of length #{credentials[:unique_id].length}"
    end
    too_many_attempts = false
    begin
      associated_shards = associated_shards(credentials[:unique_id])
    rescue => e
      # global lookups is just an optimization anyway; log an error, but continue
      # by searching all accounts the slow way
      Canvas::Errors.capture(e)
    end
    pseudonyms = Shard.partition_by_shard(account_ids) do |account_ids|
      next if GlobalLookups.enabled? && associated_shards && !associated_shards.include?(Shard.current)
      active.
        by_unique_id(credentials[:unique_id]).
        where(:account_id => account_ids).
        preload(:user).
        select { |p|
          valid = p.valid_arbitrary_credentials?(credentials[:password])
          too_many_attempts = true if p.audit_login(remote_ip, valid) == :too_many_attempts
          valid
        }
    end
    return :too_many_attempts if too_many_attempts
    pseudonyms
  end

  def self.authenticate(credentials, account_ids, remote_ip = nil)
    pseudonyms = []
    begin
      pseudonyms = find_all_by_arbitrary_credentials(credentials, account_ids, remote_ip)
    rescue ImpossibleCredentialsError => e
      Rails.logger.info("Impossible pseudonym credentials: #{credentials[:unique_id]}, invalidating session")
      return :impossible_credentials
    end
    return :too_many_attempts if pseudonyms == :too_many_attempts
    site_admin = pseudonyms.find { |p| p.account_id == Account.site_admin.id }
    # only log them in if these credentials match a single user OR if it matched site admin
    if pseudonyms.map(&:user).uniq.length == 1 || site_admin
      # prefer a pseudonym from Site Admin if possible, otherwise just choose one
      site_admin || pseudonyms.first
    end
  end

  def audit_login(remote_ip, valid_password)
    Canvas::Security::LoginRegistry.audit_login(self, remote_ip, valid_password)
  end

  def self.cas_ticket_key(ticket)
    "cas_session_slo:#{ticket}"
  end

  def cas_ticket_expired?(ticket)
    return unless Canvas.redis_enabled?
    redis_key = Pseudonym.cas_ticket_key(ticket)

    !!Canvas.redis.get(redis_key)
  end

  def self.expire_cas_ticket(ticket)
    return unless Canvas.redis_enabled?
    redis_key = cas_ticket_key(ticket)

    Canvas.redis.set(redis_key, true, ex: CAS_TICKET_TTL)
  end
end
