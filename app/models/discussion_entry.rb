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

require 'atom'

class DiscussionEntry < ActiveRecord::Base
  include Workflow
  include SendToStream
  include TextHelper
  include HtmlTextHelper

  attr_readonly :discussion_topic_id, :user_id, :parent_id
  has_many :discussion_subentries, -> { order(:created_at) }, class_name: 'DiscussionEntry', foreign_key: "parent_id"
  has_many :unordered_discussion_subentries, :class_name => 'DiscussionEntry', :foreign_key => "parent_id"
  has_many :flattened_discussion_subentries, :class_name => 'DiscussionEntry', :foreign_key => "root_entry_id"
  has_many :discussion_entry_participants
  has_one :last_discussion_subentry, -> { order(created_at: :desc) }, class_name: 'DiscussionEntry', foreign_key: 'root_entry_id'
  belongs_to :discussion_topic, inverse_of: :discussion_entries
  # null if a root entry
  belongs_to :parent_entry, :class_name => 'DiscussionEntry', :foreign_key => :parent_id
  # also null if a root entry
  belongs_to :root_entry, :class_name => 'DiscussionEntry', :foreign_key => :root_entry_id
  belongs_to :user
  has_many :mentions, inverse_of: :discussion_entry
  belongs_to :attachment
  belongs_to :editor, :class_name => 'User'
  belongs_to :root_account, class_name: 'Account'
  has_one :external_feed_entry, :as => :asset

  before_create :infer_root_entry_id
  before_create :set_root_account_id
  after_save :update_discussion
  after_save :context_module_action_later
  after_create :create_participants
  after_create :clear_planner_cache_for_participants
  validates_length_of :message, :maximum => maximum_text_length, :allow_nil => true, :allow_blank => true
  validates_presence_of :discussion_topic_id
  before_validation :set_depth, :on => :create
  validate :validate_depth, on: :create
  validate :discussion_not_deleted, on: :create
  validate :must_be_reply_to_same_discussion, on: :create

  sanitize_field :message, CanvasSanitize::SANITIZE

  # parse_and_create_mentions has to run before has_a_broadcast_policy and the
  # after_save hook it adds.
  after_save :parse_and_create_mentions
  has_a_broadcast_policy
  attr_accessor :new_record_header

  workflow do
    state :active
    state :deleted
  end

  def parse_and_create_mentions
    mention_data = Nokogiri::HTML.fragment(message).search('[data-mention]').map(&:values)
    user_ids = mention_data.map(&:first)
    User.where(id: user_ids).each do |u|
      mentions.create!(user: u, root_account_id: root_account_id)
    end
  end

  def mentioned_users
    users = User.where("EXISTS (?)", mentions.distinct.select('user_id')).to_a
    discussion_topic.filter_message_users(users)
  end

  def course_broadcast_data
    discussion_topic.context&.broadcast_data
  end

  set_broadcast_policy do |p|
    p.dispatch :new_discussion_entry
    p.to { discussion_topic.subscribers - [user] - mentioned_users }
    p.whenever { |record|
      record.just_created && record.active?
    }
    p.data { course_broadcast_data }

    p.dispatch :announcement_reply
    p.to { discussion_topic.user }
    p.whenever { |record|
      record.discussion_topic.is_announcement && record.just_created && record.active?
    }
    p.data { course_broadcast_data }
  end

  on_create_send_to_streams do
    if self.root_entry_id.nil?
      participants = discussion_topic.active_participants_with_visibility

      # If the topic has been going for more than two weeks, only show
      # people who have been participating in the topic
      if self.created_at > self.discussion_topic.created_at + 2.weeks
        participants.map(&:id) & DiscussionEntry.active.
          where('discussion_topic_id=? AND created_at > ?', self.discussion_topic_id, 2.weeks.ago).
          distinct.pluck(:user_id)
      else
        participants
      end
    else
      []
    end
  end

  # The maximum discussion entry threading depth that is allowed
  def self.max_depth
    Setting.get('discussion_entry_max_depth', '50').to_i
  end

  def self.rating_sums(entry_ids)
    sums = self.where(:id => entry_ids).where('COALESCE(rating_sum, 0) != 0')
    Hash[sums.map{|x| [x.id, x.rating_sum]}]
  end

  def set_depth
    self.depth ||= (self.parent_entry.try(:depth) || 0) + 1
  end

  def validate_depth
    if !self.depth || self.depth > self.class.max_depth
      errors.add(:base, "Maximum entry depth reached")
    end
  end

  def discussion_not_deleted
    errors.add(:base, "Requires non-deleted discussion topic") if self.discussion_topic.deleted?
  end

  def must_be_reply_to_same_discussion
    if self.parent_entry && self.parent_entry.discussion_topic_id != self.discussion_topic_id
      errors.add(:parent_id, "Parent entry must belong to the same discussion topic")
    end
  end

  def reply_from(opts)
    raise IncomingMail::Errors::UnknownAddress if self.context.root_account.deleted?
    raise IncomingMail::Errors::ReplyToDeletedDiscussion if self.discussion_topic.deleted?
    user = opts[:user]
    if opts[:html]
      message = opts[:html].strip
    else
      message = opts[:text].strip
      message = format_message(message).first
    end
    user = nil unless user && self.context.users.include?(user)
    if !user
      raise IncomingMail::Errors::InvalidParticipant
    elsif !message || message.empty?
      raise IncomingMail::Errors::BlankMessage
    else
      self.shard.activate do
        entry = discussion_topic.discussion_entries.new(message: message,
                                                        user: user,
                                                        parent_entry: self)
        if entry.grants_right?(user, :create)
          entry.save!
          entry
        else
          raise IncomingMail::Errors::ReplyToLockedTopic
        end
      end
    end
  end

  def plaintext_message=(val)
    self.message = format_message(val).first
  end

  def truncated_message(length=nil)
    plaintext_message(length)
  end

  def summary(length=150)
    HtmlTextHelper.strip_and_truncate(message, :max_length => length)
  end

  def plaintext_message(length=250)
    truncate_html(self.message, :max_length => length)
  end

  alias_method :destroy_permanently!, :destroy
  def destroy
    self.workflow_state = 'deleted'
    self.deleted_at = Time.now.utc
    save!
    update_topic_submission
    decrement_unread_counts_for_this_entry
    update_topic_subscription
  end

  def update_discussion
    if %w(workflow_state message attachment_id editor_id).any? { |a| self.saved_change_to_attribute?(a) }
      dt = self.discussion_topic
      loop do
        dt.touch
        dt = dt.root_topic
        break if dt.blank?
      end
      self.class.connection.after_transaction_commit { self.discussion_topic.update_materialized_view }
    end
  end

  def update_topic_submission
    if self.discussion_topic.for_assignment?
      entries = self.discussion_topic.discussion_entries.where(:user_id => self.user_id, :workflow_state => 'active')
      submission = self.discussion_topic.assignment.submissions.where(:user_id => self.user_id).take
      return unless submission
      if entries.any?
        submission_date = entries.order(:created_at).limit(1).pluck(:created_at).first
        if submission_date > self.created_at
          submission.submitted_at = submission_date
          submission.save!
        end
      else
        submission.workflow_state = 'unsubmitted'
        submission.submission_type = nil
        submission.submitted_at = nil
        submission.save!
      end
    end
  end

  def decrement_unread_counts_for_this_entry
    # decrement unread_entry_count for every participant that has not read the
    transaction do
      # get a list of users who have not read the entry yet
      users = discussion_topic.discussion_topic_participants.
          where(['user_id NOT IN (?)', discussion_entry_participants.read.pluck(:user_id)]).pluck(:user_id)
      # decrement unread_entry_count for topic participants
      if users.present?
        DiscussionTopicParticipant.where(:discussion_topic_id => self.discussion_topic_id, :user_id => users).
            update_all('unread_entry_count = unread_entry_count - 1')
      end
    end
  end

  def update_topic_subscription
    discussion_topic.user_ids_who_have_posted_and_admins
    unless discussion_topic.user_can_see_posts?(user)
      discussion_topic.unsubscribe(user)
    end
  end

  scope :active, -> { where("discussion_entries.workflow_state<>'deleted'") }
  scope :deleted, -> { where(:workflow_state => 'deleted') }

  def user_name
    self.user.name rescue t :default_user_name, "User Name"
  end

  def infer_root_entry_id
    # don't allow parent ids for flat discussions
    self.parent_entry = nil if self.discussion_topic.discussion_type == DiscussionTopic::DiscussionTypes::FLAT

    # only allow non-root parents for threaded discussions
    unless self.discussion_topic.try(:threaded?)
      self.parent_entry = parent_entry.try(:root_entry) || parent_entry
    end
    self.root_entry_id = parent_entry.try(:root_entry_id) || parent_entry.try(:id)
  end
  protected :infer_root_entry_id

  def update_topic
    if self.discussion_topic
      last_reply_at = [self.discussion_topic.last_reply_at, self.created_at].compact.max
      DiscussionTopic.where(:id => self.discussion_topic_id).update_all(:last_reply_at => last_reply_at, :updated_at => Time.now.utc)
    end
  end

  set_policy do
    given { |user| self.user && self.user == user }
    can :read

    given { |user| self.user && self.user == user && self.discussion_topic.available_for?(user) }
    can :reply

    given { |user| self.user && self.user == user && self.discussion_topic.available_for?(user) && context.user_can_manage_own_discussion_posts?(user) }
    can :update and can :delete

    given { |user, session| self.discussion_topic.is_announcement && self.context.grants_right?(user, session, :read_announcements) && self.discussion_topic.visible_for?(user) }
    can :read

    given { |user, session| !self.discussion_topic.is_announcement && self.context.grants_right?(user, session, :read_forum) && self.discussion_topic.visible_for?(user) }
    can :read

    given { |user, session| self.context.grants_right?(user, session, :post_to_forum) && !self.discussion_topic.locked_for?(user) && self.discussion_topic.visible_for?(user) }
    can :reply and can :create and can :read

    given { |user, session| self.context.grants_right?(user, session, :post_to_forum) && self.discussion_topic.visible_for?(user)}
    can :read

    given { |user, session| context.respond_to?(:allow_student_forum_attachments) && context.allow_student_forum_attachments && context.grants_right?(user, session, :post_to_forum) && discussion_topic.available_for?(user) }
    can :attach

    given { |user, session| !self.discussion_topic.root_topic_id && self.context.grants_right?(user, session, :moderate_forum) && !self.discussion_topic.locked_for?(user, :check_policies => true) }
    can :update and can :delete and can :reply and can :create and can :read and can :attach

    given { |user, session| !self.discussion_topic.root_topic_id && self.context.grants_right?(user, session, :moderate_forum) }
    can :update and can :delete and can :read

    given { |user, session| self.discussion_topic.root_topic && self.discussion_topic.root_topic.context.grants_right?(user, session, :moderate_forum) && !self.discussion_topic.locked_for?(user, :check_policies => true) }
    can :update and can :delete and can :reply and can :create and can :read and can :attach

    given { |user, session| self.discussion_topic.root_topic && self.discussion_topic.root_topic.context.grants_right?(user, session, :moderate_forum) }
    can :update and can :delete and can :read

    given { |user, session| self.discussion_topic.grants_right?(user, session, :rate) }
    can :rate
  end

  scope :for_user, lambda { |user| where(:user_id => user).order("discussion_entries.created_at") }
  scope :for_users, lambda { |users| where(:user_id => users) }
  scope :after, lambda { |date| where("created_at>?", date) }
  scope :top_level_for_topics, lambda { |topics| where(:root_entry_id => nil, :discussion_topic_id => topics) }
  scope :all_for_topics, lambda { |topics| where(:discussion_topic_id => topics) }
  scope :newest_first, -> { order("discussion_entries.created_at DESC, discussion_entries.id DESC") }

  def to_atom(opts={})
    author_name = self.user.present? ? self.user.name : t('atom_no_author', "No Author")
    Atom::Entry.new do |entry|
      subject = [self.discussion_topic.title]
      subject << self.discussion_topic.context.name if opts[:include_context]
      if parent_id
        entry.title = t "#subject_reply_to", "Re: %{subject}", :subject => subject.to_sentence
      else
        entry.title = subject.to_sentence
      end
      entry.authors  << Atom::Person.new(:name => author_name)
      entry.updated   = self.updated_at
      entry.published = self.created_at
      entry.id        = "tag:#{HostUrl.default_host},#{self.created_at.strftime("%Y-%m-%d")}:/discussion_entries/#{self.feed_code}"
      entry.links    << Atom::Link.new(:rel => 'alternate',
                                    :href => "http://#{HostUrl.context_host(self.discussion_topic.context)}/#{self.discussion_topic.context_prefix}/discussion_topics/#{self.discussion_topic_id}")
      entry.content   = Atom::Content::Html.new(self.message)
    end
  end

  def context
    self.discussion_topic.context
  end

  def context_id
    self.discussion_topic.context_id
  end

  def context_type
    self.discussion_topic.context_type
  end

  def title
    self.discussion_topic.title
  end

  def context_module_action_later
    delay_if_production.context_module_action
  end
  protected :context_module_action_later

  # If this discussion topic is part of an assignment this method is what
  # submits the assignment or updates the submission for the user
  def context_module_action
    if self.discussion_topic && self.user
      action = self.deleted? ? :deleted : :contributed
      self.discussion_topic.context_module_action(user, action)
    end
  end

  def create_participants
    self.class.connection.after_transaction_commit do
      scope = DiscussionTopicParticipant.where(:discussion_topic_id => self.discussion_topic_id)
      if self.discussion_topic.root_topic?
        group_ids = self.discussion_topic.group_category.groups.active.pluck(:id)
        scope = scope.where("NOT EXISTS (?)",
          GroupMembership.where("group_memberships.workflow_state <> 'deleted' AND
            group_memberships.user_id=discussion_topic_participants.user_id AND
            group_memberships.group_id IN (?)", group_ids))
      end
      scope = scope.where("user_id<>?", self.user) if self.user
      scope.update_all("unread_entry_count = unread_entry_count + 1")

      if self.user
        self.discussion_entry_participants.create!(:user => self.user, :workflow_state => "read")

        existing_topic_participant = nil
        DiscussionTopicParticipant.unique_constraint_retry do
          existing_topic_participant = self.discussion_topic.discussion_topic_participants.where(user_id: self.user).first
          unless existing_topic_participant
            new_count = self.discussion_topic.default_unread_count - 1
            self.discussion_topic.discussion_topic_participants.create!(
              :user => self.user,
              :unread_entry_count => new_count,
              :workflow_state => "unread",
              :subscribed => !self.discussion_topic.subscription_hold(user, nil, nil)
            )
          end
        end
        if existing_topic_participant && !existing_topic_participant.subscribed? && !self.discussion_topic.subscription_hold(user, nil, nil)
          existing_topic_participant.update!(:subscribed => true)
        end
      end
    end
  end

  def clear_planner_cache_for_participants
    # If this is a top level reply we do not need to clear the cache here,
    # because the creation of this object will also create a stream item which
    # takes care of clearing the cache
    self.class.connection.after_transaction_commit do
      if self.root_entry_id.present?
        if self.discussion_topic.for_assignment? || self.discussion_topic.todo_date.present?
          User.where(:id => self.discussion_topic.discussion_topic_participants.select(:user_id)).touch_all
        end
      end
    end
  end

  attr_accessor :current_user
  def read_state(current_user = nil)
    current_user ||= self.current_user
    return "read" unless current_user # default for logged out users
    find_existing_participant(current_user).workflow_state
  end

  def rating(current_user = nil)
    current_user ||= self.current_user
    return nil unless current_user # default for logged out users
    find_existing_participant(current_user).rating
  end

  def read?(current_user = nil)
    read_state(current_user) == "read"
  end

  def unread?(current_user = nil)
    !read?(current_user)
  end

  # Public: Change the workflow_state of the entry for the specified user.
  #
  # new_state    - The new workflow_state.
  # current_user - The User to to change state for. This function does nothing
  #                if nil is passed. (default: self.current_user)
  # opts         - Additional named arguments (default: {})
  #                :forced - Also set the forced_read_state to this value.
  #
  # Returns nil if current_user is nil, the DiscussionEntryParticipant if the
  # read_state was changed, or true if the read_state was not changed. If the
  # read_state is not changed, a participant record will not be created.
  def change_read_state(new_state, current_user = nil, opts = {})
    current_user ||= self.current_user
    return nil unless current_user

    if new_state != self.read_state(current_user)
      entry_participant = self.update_or_create_participant(opts.merge(:current_user => current_user, :new_state => new_state))
      if entry_participant.present? && entry_participant.valid?
        self.discussion_topic.update_or_create_participant(opts.merge(:current_user => current_user, :offset => (new_state == "unread" ? 1 : -1)))
      end
      entry_participant
    else
      true
    end
  end

  # Public: Change the rating of the entry for the specified user.
  #
  # new_rating    - The new rating.
  # current_user - The User to to change state for. This function does nothing
  #                if nil is passed. (default: self.current_user)
  #
  # Returns nil if current_user is nil, the DiscussionEntryParticipent if the
  # rating was changed, or true if the rating was not changed. If the
  # rating is not changed, a participant record will not be created.
  def change_rating(new_rating, current_user = nil)
    current_user ||= self.current_user
    return nil unless current_user

    entry_participant = nil
    transaction do
      lock!
      old_rating = self.rating(current_user)
      if new_rating == old_rating
        return true
      end

      entry_participant = self.update_or_create_participant(current_user: current_user, rating: new_rating)

      update_aggregate_rating(old_rating, new_rating)
    end

    entry_participant
  end

  def update_aggregate_rating(old_rating, new_rating)
    count_delta = (new_rating.nil? ? 0 : 1) - (old_rating.nil? ? 0 : 1)
    sum_delta = new_rating.to_i - old_rating.to_i

    DiscussionEntry.where(id: id). update_all([
      'rating_count = COALESCE(rating_count, 0) + ?,
        rating_sum = COALESCE(rating_sum, 0) + ?',
      count_delta,
      sum_delta
    ])
    self.discussion_topic.update_materialized_view
  end

  # Public: Update and save the DiscussionEntryParticipant for a specified user,
  # creating it if necessary. This function properly handles race conditions of
  # calling this function simultaneously in two separate processes.
  #
  # opts - The options for this operation
  #        :current_user - The User that should have its participant updated.
  #                        (default: self.current_user)
  #        :new_state    - The new workflow_state for the participant.
  #        :forced       - The new forced_read_state for the participant.
  #
  # Returns the DiscussionEntryParticipant for the specified User, or nil if no
  # current_user is specified.
  def update_or_create_participant(opts={})
    current_user = opts[:current_user] || self.current_user
    return nil unless current_user

    entry_participant = nil
    DiscussionEntry.uncached do
      DiscussionEntry.unique_constraint_retry do
        entry_participant = self.discussion_entry_participants.where(:user_id => current_user).first
        entry_participant ||= self.discussion_entry_participants.build(:user => current_user, :workflow_state => "unread")
        entry_participant.workflow_state = opts[:new_state] if opts[:new_state]
        entry_participant.forced_read_state = opts[:forced] if opts.key?(:forced)
        entry_participant.rating = opts[:rating] if opts.key?(:rating)
        entry_participant.save
      end
    end
    entry_participant
  end

  # Public: Find the existing DiscussionEntryParticipant, or create a default
  # participant, for the specified user.
  #
  # user - The User to lookup the participant for.
  #
  # Returns the DiscussionEntryParticipant for the user, or a participant with
  # default values set. The returned record is marked as readonly! If you need
  # to update a participant, use the #update_or_create_participant method
  # instead.
  def find_existing_participant(user)
    participant = discussion_entry_participants.loaded? ?
      discussion_entry_participants.detect{|dep| dep.user_id == user.id} :
      discussion_entry_participants.where(:user_id => user).first
    unless participant
      # return a temporary record with default values
      participant = DiscussionEntryParticipant.new({
        :workflow_state => "unread",
        :forced_read_state => false,
        })
      participant.discussion_entry = self
      participant.user = user
    end

    # Do not save this record. Use update_or_create_participant instead if you need to save it
    participant.readonly!
    participant
  end

  def set_root_account_id
    self.root_account_id ||= self.discussion_topic.root_account_id
  end
end
