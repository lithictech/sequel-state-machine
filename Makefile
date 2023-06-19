VERSION := `cat lib/state_machines/sequel/version.rb | grep 'VERSION =' | cut -d '"' -f2`

install:
	bundle install
cop:
	bundle exec rubocop
fix:
	bundle exec rubocop --auto-correct-all
fmt: fix

up:
	@docker-compose up -d

down:
	docker-compose down
psql:
	psql postgres://ostest:ostest@localhost:11101/ostest

test:
	bundle exec rspec spec/
	DATABASE_URL=postgres://ostest:ostest@localhost:11101/ostest bundle exec rspec spec/

build:
ifeq ($(strip $(VERSION)),)
	echo "Could not parse VERSION"
else
	git tag $(VERSION)
	gem build sequel-state-machine.gemspec
	gem push sequel-state-machine-$(VERSION).gem
	git push origin $(VERSION)
endif

