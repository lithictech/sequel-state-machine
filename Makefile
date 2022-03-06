install:
	bundle install
cop:
	bundle exec rubocop
fix:
	bundle exec rubocop --auto-correct-all
fmt: fix

test:
	RACK_ENV=test bundle exec rspec spec/
testf:
	RACK_ENV=test bundle exec rspec spec/ --fail-fast --seed=1

build:
	gem build sequel-state-machine.gemspec
	# gem push sequel-state-machine-x.y.z.gem
