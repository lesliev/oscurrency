# == Schema Information
#
# Table name: topics
#
#  id                :integer          not null, primary key
#  forum_id          :integer
#  person_id         :integer
#  name              :string(255)
#  forum_posts_count :integer          default(0), not null
#  created_at        :datetime
#  updated_at        :datetime
#

class Topic < ActiveRecord::Base
  include ActivityLogger

  MAX_NAME = 100
  NUM_RECENT = 6
  DEFAULT_REFRESH_SECONDS = 30

  attr_accessible :name

  belongs_to :forum, :counter_cache => true
  belongs_to :person
  has_many :posts,
           -> { order(created_at: :desc) },
           :dependent => :destroy,
           :class_name => "ForumPost"
  has_many :viewers, :dependent => :destroy
  has_many :activities, :as => :item, :dependent => :destroy
  validates_presence_of :name, :forum, :person
  validates_length_of :name, :maximum => MAX_NAME

  after_create :log_activity

  def self.find_recent
    order(created_at: :desc).limit(NUM_RECENT)
  end

  def self.find_recently_active(forum, params_per_page, page = 1)
    forum.topics.paginate(:page => page, :per_page => params_per_page)
  end

  def update_viewer(person)
    current_viewer = self.viewers.find_or_create_by_person_id(person.id)
    current_viewer.touch
  end

  def current_viewers(seconds_ago)
    viewers.includes(:person).where('updated_at > ?', Time.now.ago(seconds_ago).utc)
  end

  def posts_since_last_refresh(last_refresh_time, person_id)
    posts
      .includes(:person)
      .where('created_at > ?', Time.at(last_refresh_time + 1).utc)
      .where('person_id != ?', person_id)
      .order(created_at: :desc)
  end

  private

    def log_activity
      add_activities(:item => self, :person => person, :group => self.forum.group)
    end
end
