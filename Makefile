VERSION := `cat lib/state_machines/sequel/version.rb | grep 'VERSION =' | cut -d '"' -f2`

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
ifeq ($(strip $(VERSION)),)
	echo "Could not parse VERSION"
else
	git tag $(VERSION)
	gem build sequel-state-machine.gemspec
	gem push sequel-state-machine-$(VERSION).gem
	git push origin $(VERSION)
endif

