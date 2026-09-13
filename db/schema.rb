# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[7.1].define(version: 2026_08_02_163011) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "plpgsql"

  create_table "addons", force: :cascade do |t|
    t.bigint "app_id", null: false
    t.string "kind"
    t.string "name"
    t.string "status"
    t.text "config"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["app_id"], name: "index_addons_on_app_id"
  end

  create_table "apps", force: :cascade do |t|
    t.string "name"
    t.string "kind"
    t.string "repository_url"
    t.string "branch"
    t.bigint "user_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "port"
    t.string "subdomain"
    t.string "webhook_secret"
    t.string "cpu_limit"
    t.string "memory_limit"
    t.string "runtime_status"
    t.string "coolify_uuid"
    t.string "build_pack", default: "nixpacks"
    t.string "docker_compose_location"
    t.text "docker_compose_raw"
    t.string "deployment_type"
    t.index ["coolify_uuid"], name: "index_apps_on_coolify_uuid"
    t.index ["subdomain"], name: "index_apps_on_subdomain"
    t.index ["user_id"], name: "index_apps_on_user_id"
  end

  create_table "backup_configurations", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "s3_access_key_id"
    t.string "s3_secret_access_key"
    t.string "s3_bucket"
    t.string "s3_region"
    t.string "s3_endpoint"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id"], name: "index_backup_configurations_on_user_id"
  end

  create_table "backups", force: :cascade do |t|
    t.string "status"
    t.string "filename"
    t.integer "size"
    t.string "s3_key"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.bigint "addon_id"
    t.index ["addon_id"], name: "index_backups_on_addon_id"
    t.index ["user_id"], name: "index_backups_on_user_id"
  end

  create_table "deployments", force: :cascade do |t|
    t.bigint "app_id", null: false
    t.string "status"
    t.text "log"
    t.string "commit_sha"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["app_id"], name: "index_deployments_on_app_id"
  end

  create_table "domains", force: :cascade do |t|
    t.bigint "app_id", null: false
    t.string "fqdn"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["app_id"], name: "index_domains_on_app_id"
    t.index ["fqdn"], name: "index_domains_on_fqdn"
  end

  create_table "environment_variables", force: :cascade do |t|
    t.bigint "app_id", null: false
    t.string "key"
    t.text "value"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["app_id"], name: "index_environment_variables_on_app_id"
  end

  create_table "storages", force: :cascade do |t|
    t.bigint "app_id", null: false
    t.string "name"
    t.string "source"
    t.string "destination"
    t.boolean "is_directory", default: true
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["app_id"], name: "index_storages_on_app_id"
  end

  create_table "users", force: :cascade do |t|
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.string "reset_password_token"
    t.datetime "reset_password_sent_at"
    t.datetime "remember_created_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "jti"
    t.string "github_token"
    t.string "github_username"
    t.string "gitlab_token"
    t.string "gitlab_username"
    t.string "plan", default: "spark"
    t.string "stripe_customer_id"
    t.string "stripe_subscription_id"
    t.string "google_uid"
    t.string "google_token"
    t.string "google_username"
    t.boolean "god_mode", default: false
    t.string "name"
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["google_uid"], name: "index_users_on_google_uid"
    t.index ["jti"], name: "index_users_on_jti"
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
    t.index ["stripe_customer_id"], name: "index_users_on_stripe_customer_id"
    t.index ["stripe_subscription_id"], name: "index_users_on_stripe_subscription_id"
  end

  add_foreign_key "addons", "apps"
  add_foreign_key "apps", "users"
  add_foreign_key "backup_configurations", "users"
  add_foreign_key "backups", "addons"
  add_foreign_key "backups", "users"
  add_foreign_key "deployments", "apps"
  add_foreign_key "domains", "apps"
  add_foreign_key "environment_variables", "apps"
  add_foreign_key "storages", "apps"
end
