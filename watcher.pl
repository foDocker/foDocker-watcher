#!/usr/bin/env perl
use Mojolicious::Lite;
use Mojo::JSON qw/from_json/;
use Mojo::EventEmitter;
use Mojo::UserAgent;
use File::Path qw/rmtree/;
use Mojo::Util qw/url_escape/;
use MongoDB;
use YAML;

helper ua => sub {
	state $ua ||= Mojo::UserAgent->new;
	$ua->inactivity_timeout(300);
	$ua
};

helper mongo => sub {
	state $mongo ||= MongoDB->connect('mongodb://mongo')
};

helper db => sub {
	my $c		= shift;
	state $db	||= $c->app->mongo->get_database("watcher");
};

helper separe_file => sub {
	my $c		= shift;
	my $file	= Load(shift);

	my(%scale, %alerts, %metrics, $stack);
	$c->app->log->debug($c->app->dumper($file));
	if(exists $file->{services}) {
		for my $service(keys %{ $file->{services} }) {
			next unless exists $file->{services}{$service}{scaling};
			$scale{$service} = delete $file->{services}{$service}{scaling};
			$scale{$service}{min} = 0 unless exists $scale{$service}{min};
			$scale{$service}{initial} = $scale{$service}{min}
				if exists $scale{$service}{min}
					and (
						not exists $scale{$service}{initial}
						or $scale{$service}{initial} < $scale{$service}{min}
					)
			;
		}
	}
	if(exists $file->{stack_name}) {
		$stack = delete $file->{stack_name}
	}
	if(exists $file->{alerts}) {
		%alerts = %{ delete $file->{alerts} }
	}
	if(exists $file->{metrics}) {
		my $metrics = delete $file->{metrics};
		%metrics = ref $metrics eq "ARRAY" ? map {($_ => 1)} @$metrics : %$metrics
	}

	{compose => $file, scale => \%scale, alerts => \%alerts, metrics => \%metrics, stack => $stack}
};

helper timers => sub {
	state $timers ||= {};
};

helper stack_data_cache => sub {
	state $cache ||= {};
};

helper get_stack_data => sub {
	my $c		= shift;
	my $stack	= shift;
	if(exists $c->stack_data_cache->{$stack}) {
		return $c->stack_data_cache->{$stack}->{data}
	}
	my $col		= $c->db->get_collection("stacks");
	my($data)	= $col->find({_id => $stack})->all;
	$c->app->log->debug("stack data:", $c->app->dumper($data));
	$c->stack_data_cache->{$stack}->{data}	= $data;
	$c->stack_data_cache->{$stack}->{timer}	= Mojo::IOLoop->timer(sub {
		delete $c->stack_data_cache->{$stack};
	});
	$data
};

helper get_data => sub {
	my $c		= shift;
	my $stack	= shift;
	my $type	= shift;
	my $col		= $c->db->get_collection("stacks");
	my $data	= $c->get_stack_data($stack)->{$type};
	$c->app->log->debug("$type:", $c->app->dumper($data));
	$data
};

helper call_compose_to_create_stack => sub {
	my $c		= shift;
	my $stack	= shift;
	my $compose	= shift;
	my $cb		= shift;

	$c->ua->post("http://composeapi:3000/$stack" => json => $compose => sub {
		my $ua	= shift;
		my $tx	= shift;
		if($tx->error or not $tx->res->json->{ok}) {
			$c->app->log->error($tx->error->{message});
			die  $tx->error->{message}
		}
		$c->app->log->debug($c->app->dumper($tx->res->json));
		$cb->($tx->res->json);
	});
};

helper create_stack => sub {
	my $c		= shift;
	my $stack	= shift;
	my $cb		= shift;

	my $compose = $c->get_data($stack, "compose");
	my $git = $c->get_data($stack, "git");
	$c->app->log->debug("git: $git");
	$c->app->log->debug("compose yml:", $c->app->dumper($compose));
	# test git
	my $url;
	if(not defined $git) {
		$c->call_compose_to_create_stack($stack, $compose, $cb)
	} else {
		$c->ua->post("http://composeapi:3000/$stack/git" => form => {git => $git} => sub {
			my $ua	= shift;
			my $tx	= shift;
			if($tx->error or not $tx->res->json->{ok}) {
				$c->app->log->error($tx->error->{message});
				die  $tx->error->{message}
			}
			$c->app->log->debug($c->app->dumper($tx->res->json));
			$c->call_compose_to_create_stack($stack, $compose, $cb);
		});
	}
};

helper del_stack => sub {
	my $c		= shift;
	my $stack	= shift;
	my $cb		= shift;

	my $compose = $c->get_data($stack, "compose");
	$c->app->log->debug("compose yml:", $c->app->dumper($compose));
	my $metrics = $c->get_data($stack, "metrics");
	if($metrics) {
		for my $metric(keys %$metrics) {
			Mojo::IOLoop->remove($c->timers->{metric}{$stack}{$metric});
		}
		delete $c->timers->{metric}{$stack};
	}
	$c->ua->delete("http://composeapi:3000/$stack/run" => sub {
		$c->ua->delete("http://composeapi:3000/$stack/file" => sub {
			my $ua	= shift;
			my $tx	= shift;
			if($tx->error or !$tx->res->json->{ok}) {
				$c->app->log->error($tx->error->{message});
				die $tx->error->{message}
			}
			$c->app->log->debug($c->app->dumper($tx->res->json));
			$cb->($tx->res->json);
		});
	});
};

helper ee => sub{
	state $ee ||= Mojo::EventEmitter->new
};

helper influxdb_write => sub {
	my $c		= shift;
	my $metric	= shift;
	my $tags	= shift;
	my $values	= shift;
	my $data = join(" ", join(",", $metric, map{"$_=$tags->{$_}"} keys %$tags), join ",", map{"$_=$values->{$_}"} keys %$values);
	$c->app->log->debug(("=" x 30) . "> WRITE: http://influxdb:8086/write?db=fodocker" => $data);
	$c->ua->post("http://influxdb:8086/write?db=fodocker" => $data => sub {
		my $ua	= shift;
		my $tx	= shift;

		if(my $res = $tx->success) {
			$c->app->log->debug("influxdb error:", $c->app->dumper($res->json));
		} else {
			$c->app->log->error("influxdb error:", $tx->error->{message});
		}
	});
};

helper influxdb_query => sub {
	my $c		= shift;
	my $query	= shift;
	my $cb		= shift;
	$c->app->log->debug("QUERY: $query");
	$c->ua->get("http://influxdb:8086/query?db=fodocker&q=" . url_escape($query) => sub {
		my $ua	= shift;
		my $tx	= shift;

		if(my $res = $tx->success) {
			my @objs;
			if($res->json("/results/0/series/0/columns")) {
				my @columns = @{ $res->json("/results/0/series/0/columns") };
				for my $values(@{ $res->json("/results/0/series/0/values") }) {
					my %tmp;
					@tmp{@columns} = @{ $values };
					push @objs, \%tmp
				}
				$c->app->log->debug("response from influxdb:", $c->app->dumper((grep {keys %$_ >= 1} @objs)[-1]{value}));
			}
			$c->app->log->debug(("-" x 90) . "> value:", $c->app->dumper(@objs));
			$cb->(@objs)
		} else {
			$c->app->log->error("influxdb error:", $tx->error->{message});
			die $tx->error->{message}
		}
	});
};

helper comparations => sub {
	state $cmp ||= {
		"=="		=> sub {shift() == shift()},
		"!="		=> sub {shift() != shift()},
		">"		=> sub {shift() >  shift()},
		"<"		=> sub {shift() <  shift()},
		">="		=> sub {shift() >= shift()},
		"<="		=> sub {shift() <= shift()},
		"=~"		=> sub {
			my $val = shift;
			my $match = shift;
			$val =~ /$match/
		},
		"!~"		=> sub {
			my $val = shift;
			my $match = shift;
			$val !~ /$match/
		},
		"between"	=> sub {
			my $val = shift;
			my ($min, $max) = split /\s+/, shift;
			$min < $val && $val < $max
		},
		"not\\s+between"	=> sub {
			my $val = shift;
			my ($min, $max) = split /\s+/, shift;
			$min > $val || $val > $max
		},
	};

};

helper create_metrics => sub {
	my $c		= shift;
	my $stack	= shift;

	my $metrics = $c->get_data($stack, "metrics");
	if($metrics) {
		for my $metric(keys %$metrics) {
			$c->recurring_metric($stack, $metric, $metrics->{$metric})
		}
	}
};

helper create_alerts => sub {
	my $c		= shift;
	my $stack	= shift;

	my $alerts = $c->get_data($stack, "alerts");
	if($alerts) {
		for my $alert(keys %$alerts) {
			$c->app->log->debug("alert: $alert");
			for my $metric(keys %{ $alerts->{$alert} }) {
				my $ops = join "|", sort {length $b <=> length $a} keys %{ $c->comparations };
				my ($op, $val) = ($1, $2) if $alerts->{$alert}{$metric} =~ /^\s*($ops)\s*(.*?)$/i;
				die "Not a valid constraint: $metric: $alerts->{$alert}{$metric}" unless defined $op and defined $val;
				$c->ee->on("metric $metric" => sub {
					$c->app->log->debug(("-" x 60) . "testing alert: $alert");
					my $ee		= shift;
					my $value	= shift;

					$c->app->log->info("\$c->comparations->{$op}->($value, $val)");
					if($c->comparations->{$op}->($value, $val)) {
						$c->app->log->debug("emit alert $stack $alert");
						$c->ee->emit("alert $stack $alert")
					}
				})
			}
		}
	}

};

helper create_autoscale => sub {
	my $c		= shift;
	my $stack	= shift;

	my $scale = $c->get_data($stack, "scale");
	if($scale) {
		for my $service(keys %{ $scale }) {
			if(exists $scale->{$service}->{on_alert}) {
				my $on_alert = $scale->{$service}->{on_alert};
				for my $alert(keys %{ $on_alert }) {
					$c->ee->on("alert $stack $alert" => sub {
						$c->scale_stack($stack, {$service => $on_alert->{$alert}});
					});
				}
			}
		}
	}
};

helper create_fixer => sub {
	my $c		= shift;
	my $stack	= shift;

	if(exists $c->timers->{stack}{$stack}) {
		Mojo::IOLoop->remove($c->timers->{stack}{$stack})
	}

	$c->timers->{stack}{$stack} = Mojo::IOLoop->recurring(15 => sub {
		$c->fix_instances($stack);
	});
};

helper scale_stack => sub {
	my $c		= shift;
	$c->app->log->debug("scale_stack(@_)");
	my $stack	= shift;
	my $scale	= shift;
	my $cb		= shift;
	my $min		= $c->min_scale($stack);
	my $max		= $c->max_scale($stack);

	for my $service(keys %$scale) {
		if(exists $min->{$service} or exists $max->{$service}) {
			$scale->{$service} = {value => $scale->{$service}}
		}
		$scale->{$service}{min} = $min->{$service} if exists $min->{$service};
		$scale->{$service}{max} = $max->{$service} if exists $max->{$service};
	}

	$c->ua->post("http://composeapi:3000/$stack/run" => json => $scale => sub {
		my $ua	= shift;
		my $tx	= shift;
		if($tx->error) {
			$c->app->log->error($tx->error->{message});
			die $tx->error->{message}
		}
		my $scale_res = $tx->res->json;
		for my $service(keys %$scale_res) {
			$c->influxdb_write("scale_stack", {stack => $stack, service => $service}, {value => $scale_res->{$service}});
		}
		$cb->($scale_res) if $cb
	});
};

helper run_stack => sub {
	my $c		= shift;
	$c->app->log->debug("run_stack(@_)");
	my $stack	= shift;
	my $cb		= pop;
	my $scale;
	if(ref $cb eq "CODE") {
		$scale	= shift // $c->initial_scale($stack);
	} else {
		$scale = $cb;
		undef $cb
	}

	$c->influxdb_write("start_stack", {stack => $stack}, {value => 1});

	$c->create_autoscale($stack);
	$c->create_fixer($stack);
	$c->create_metrics($stack);
	$c->create_alerts($stack);
	$c->scale_stack($stack, $scale => $cb);
};

helper recurring_metric => sub {
	my $c		= shift;
	my $stack	= shift;
	my $metric	= shift;
	my $conf	= shift;

	$c->app->log->debug("recurring_metric $stack, $metric: $conf");

	if(exists $c->timers->{metric}{$stack} and exists $c->timers->{metric}{$stack}{$metric}) {
		Mojo::IOLoop->remove($c->timers->{metric}{$stack}{$metric})
	}
	$c->timers->{metric}{$stack}{$metric} = Mojo::IOLoop->recurring(15 => sub {
		$c->get_metric($metric, $stack => sub {
			my $value = shift;
			$c->app->log->debug("METRIC $metric: $value <" . ("-" x 30));
			$c->ee->emit("metric $metric", $value);
		});
	});
};

helper get_metric => sub {
	my $c		= shift;
	my $metric	= shift;
	my $stack	= shift;
	my $cb		= shift;

	$c->influxdb_query(qq{select mean("value") from "$metric" where time > now() - 15s group by time(15s) fill(none)} => sub {
		$c->app->log->debug(("-" x 90) . "value:", $c->app->dumper(@_));
		my $data = pop;
		$cb->($data->{mean});
	});
};

helper fix_instances => sub {
	my $c		= shift;
	my $stack	= shift;
	my $scale	= {};

	$c->get_stack_scale($stack => sub {
		my $actual	= shift;
		my $min		= $c->min_scale($stack);
		my $max		= $c->max_scale($stack);

		for my $serv(keys %$actual) {
			if(exists $min->{$serv} and $actual->{$serv} < $min->{$serv}) {
				$scale->{$serv} = $min->{$serv};
			} elsif(exists $max->{$serv} and $actual->{$serv} > $max->{$serv}) {
				$scale->{$serv} = $max->{$serv};
			}
		}

		$c->scale_stack($stack => $scale);
	});
};

helper get_stack_scale => sub {
	my $c		= shift;
	my $stack	= shift;
	my $cb		= shift;

	$c->ua->get("http://composeapi:3000/$stack/run" => sub {
		my $ua	= shift;
		my $tx	= shift;
		if($tx->error) {
			$c->app->log->error($tx->error->{message});
			die $tx->error->{message}
		}
		$c->app->log->debug($c->app->dumper($tx->res->json));
		$cb->($tx->res->json) if $cb
	});
};

helper max_scale => sub {
	my $c		= shift;
	my $stack	= shift;
	my $col		= $c->db->get_collection("stacks");
	my $scale	= $c->get_data($stack, "scale");

	my %max = map {($_ => $scale->{$_}{max})} keys %$scale;
	$c->app->log->debug("max:", $c->app->dumper(\%max));
	\%max
};

helper min_scale => sub {
	my $c		= shift;
	my $stack	= shift;
	my $col		= $c->db->get_collection("stacks");
	my $scale	= $c->get_data($stack, "scale");

	my %min = map {($_ => $scale->{$_}{min})} keys %$scale;
	$c->app->log->debug("min:", $c->app->dumper(\%min));
	\%min
};

helper initial_scale => sub {
	my $c		= shift;
	my $stack	= shift;
	my $col		= $c->db->get_collection("stacks");
	my $scale	= $c->get_data($stack, "scale");

	my %initial = map {($_ => $scale->{$_}{initial})} keys %$scale;
	$c->app->log->debug("initail:", $c->app->dumper(\%initial));
	\%initial
};

helper create_and_run_stack => sub {
	my $c		= shift;
	my $stack	= shift;
	my $data	= shift;

	$c->app->log->debug($c->app->dumper($data));
	my $col = $c->db->get_collection("stacks");
	eval {$col->insert_one({ _id => $stack, %$data }) };
	$col->update_one({ _id => $stack}, {'$set' => $data}) if $@;
	$c->create_stack($stack => sub {
		$c->run_stack($stack => sub {
			my $scales = shift;
			$c->render(json => {ok => \1, scales => $scales});
		});
	});
};

helper get_from_file_or_git => sub {
	my $c		= shift;
	my $file	= $c->param("file") || "./fodocker.yml";
	my $git		= $c->param("git");
	my $data;
	die "no file" unless defined $c->param("file") or defined $git;
	if(not defined $git) {
		$file	= $c->param("file")->slurp;
		$data	= $c->separe_file($file);
	} else {
		system "git clone -n $git --depth 1 /tmp/tmp_repo && cd /tmp/tmp_repo && git checkout HEAD $file";
		open my $FILE, "<", "/tmp/tmp_repo/$file" || die $!;
		$file = join "", <$FILE>;
		$c->app->log->debug("FILE => $file");
		rmtree "/tmp/tmp_repo";
		$data = $c->separe_file($file);
		$data->{git} = $git;
		$c->app->log->debug("DATA => ", $c->app->dumper($data))
	}
	$data
};

post "/" => sub {
	my $c	= shift;
	my $data = $c->get_from_file_or_git;
	die "no stack name defined" unless exists $data->{stack};
	$c->create_and_run_stack($data->{stack}, $data);
	$c->render_later
};

post "/:stack" => sub {
	my $c	= shift;
	die "no file" unless $c->param("file");
	my $stack = $c->param("stack");
	my $data = $c->get_from_file_or_git;
	$c->create_and_run_stack($stack, $data);
	$c->render_later
};

get "/:stack" => sub {
	my $c	= shift;
	my $stack = $c->param("stack");
	my $col = $c->db->get_collection("stacks");
	my ($conf) = $col->find({ _id => $stack })->all;
	$c->render(json => $conf)
};

del "/:stack" => sub {
	my $c	= shift;
	my $stack = $c->param("stack");
	$c->del_stack($stack => sub {
		Mojo::IOLoop->remove($c->timers->{stack}{$stack});
		my $col = $c->db->get_collection("stacks");
		my ($conf) = $col->delete_many({ _id => $stack });
		$c->render(json => $conf->deleted_count)
	});
	$c->render_later
};

app->start;
