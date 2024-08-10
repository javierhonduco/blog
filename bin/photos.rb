require 'bundler/inline'
require 'yaml'
require 'digest'
require 'image_processing/mini_magick'

gemfile do
  source 'https://rubygems.org'
  gem 'exif'
  gem 'image_processing'
  gem 'nokogiri'
  gem 'aws-sdk-s3'
end

S3_ACCESS_KEY_ID = ENV.fetch('S3_ACCESS_KEY_ID')
S3_SECRET_ACCESS_KEY = ENV.fetch('S3_SECRET_ACCESS_KEY')
S3_ENDPOINT = ENV.fetch('S3_ENDPOINT')
BUCKET_NAME = 'blog-photos'
PHOTOS_YAML = '_data/photos.yml'
PHOTOS_SOURCE_GLOB = 'images/photos/*' # TODO: make this configurable

Photo = Data.define(
    :description,
    :location,
    :original_url,
    :original_name,
    :date,
    :tags,
    :name,
    :sha256_hash
)

photo_db = (YAML.load_file(PHOTOS_YAML) || []).map do |photo|
    Photo.new(description: photo['description'], location: photo['location'], original_url: photo['original_url'], original_name: photo['original_name'], date: photo['date'], tags: photo['tags'], name: photo['name'], sha256_hash: photo['sha256_hash'])
end


def find_photo_by_hash(photo_db, sha256_hash)
    photo_db.each do |photo|
        if photo.sha256_hash == sha256_hash
            return photo
        end
    end

    return nil
end

def add_photo(original_name, photo, exif, photo_db, sha256_hash)
    photo_db << Photo.new(description: '', location: '', original_url: '', original_name: original_name, date: exif.date_time, tags: '', name: '', sha256_hash: sha256_hash)
end

# TODO: run concurrently
def resize_photo(photo_path)
    res = {}
    ["webp", "jpg"].each do |format|
        [640, 1280, 2880, nil].each do |width|
            pipeline = ImageProcessing::MiniMagick
                .source(photo_path)
                .convert("webp")
            unless width.nil?
                pipeline = pipeline.resize_to_limit(width, nil)
            end

            width = width.nil? ? 'original' : width
            processed = pipeline.call
            puts processed.path
            puts "done #{format} #{width}"
            res["#{format}_#{width}"] = processed
        end
    end
    res
end

def upload_to_s3(file_path, name)
    s3 = Aws::S3::Resource.new(access_key_id: S3_ACCESS_KEY_ID, secret_access_key: S3_SECRET_ACCESS_KEY, endpoint: S3_ENDPOINT, region: 'auto')
    bucket = s3.bucket(BUCKET_NAME)
    bucket.object(name).upload_file(file_path)
    puts "uploaded #{name} to blob storage"
end

Dir.glob(PHOTOS_SOURCE_GLOB) do |photo_path|
    name = photo_path.split('/').last
    photo = File.read(photo_path)

    exif = Exif::Data.new(photo)
    sha256_hash = Digest::SHA256.hexdigest(photo)

    found_photo = find_photo_by_hash(photo_db, sha256_hash)
    if found_photo.nil?
        puts "=> adding pic"
        all_sizes_and_formats = resize_photo(photo_path)
        all_sizes_and_formats.each do |key, processed|
            format_ = key.split('_').first
            width = key.split('_').last
            upload_to_s3(processed.path, "#{sha256_hash}_#{format_}_#{width}")
        end
        add_photo(name, photo, exif, photo_db, sha256_hash)
    else
        puts "[x] found pic"
    end
end

File.write(PHOTOS_YAML, YAML.dump(photo_db.map { |photo| photo.to_h.transform_keys(&:to_s) })) # TODO: sort by date