#!/usr/bin/perl

use v5.10;
use strict;
use warnings;

use File::Slurp qw(slurp write_file);
use File::stat;
use File::Touch;
use Data::Dumper qw(Dumper);
use Carp;
use Term::ANSIColor;
use Term::ReadKey;
use List::Util qw(first unpairs);
use Clone qw(clone);

sub get_deps {
    my ($config, %fdeps) = @_;

    my %deps;

    return { } unless $config =~ /\{\s*deps\s*,\s*\[(.*?)\]/s;
    my $sdeps = $1;

    while ($sdeps =~ /\{\s* (\w+) \s*,\s* ".*?" \s*,\s* \{\s*git \s*,\s* "(.*?)" \s*,\s*
                      (?:
                        (?:{\s*tag \s*,\s* "(.*?)") |
                        "(.*?)" |
                        ( \{ (?: (?-1) | [^{}]+ )+ \} ) )/sgx) {
        next unless not %fdeps or exists $fdeps{$1};
        $deps{$1} = { repo => $2, commit => $3 || $4 };
    }
    return \%deps;
}
my (%info_updates, %top_deps_updates, %sub_deps_updates, @operations);

sub top_deps {
    state %deps;
    if (not %deps) {
        my $config = slurp "rebar.config";
        croak "Unable to extract floating_deps" unless $config =~ /\{floating_deps, \[(.*?)\]/s;

        my $fdeps = $1;
        $fdeps =~ s/\s*//g;
        my %fdeps = map { $_ => 1 } split /,/, $fdeps;
        %deps = %{get_deps($config, %fdeps)};
    }
    return {%deps, %top_deps_updates};
}

sub update_deps_repos {
    my $deps = top_deps();
    mkdir(".deps-update") unless -d ".deps-update";
    for my $dep (keys %{$deps}) {
        my $dd = ".deps-update/$dep";
        if (not -d $dd) {
            say "Downloading $dep...";
            my $repo = $deps->{$dep}->{repo};
            $repo =~ s!^https?://github.com/!git\@github.com:!;
            system("git", "-C", ".deps-update", "clone", $repo);
        } elsif (time() - stat($dd)->mtime > 24 * 60 * 60) {
            say "Updating $dep...";
            system("git", "-C", $dd, "pull");
            touch($dd)
        }
    }
}

sub sub_deps {
    state %sub_deps;
    if (not %sub_deps) {
        my $deps = top_deps();
        for my $dep (keys %{$deps}) {
            my $rc = ".deps-update/$dep/rebar.config";
            $sub_deps{$dep} = { };
            next unless -f $rc;
            $sub_deps{$dep} = get_deps(scalar(slurp($rc)));
        }
    }
    return {%sub_deps, %sub_deps_updates};
}

sub rev_deps_helper {
    my ($rev_deps, $dep) = @_;
    if (not exists $rev_deps->{$dep}->{indirect}) {
        my %deps = %{$rev_deps->{$dep}->{direct} || {}};
        for (keys %{$rev_deps->{$dep}->{direct}}) {
            %deps = (%deps, %{rev_deps_helper($rev_deps, $_)});
        }
        $rev_deps->{$dep}->{indirect} = \%deps;
    }
    return $rev_deps->{$dep}->{indirect};
}

sub rev_deps {
    state %rev_deps;
    if (not %rev_deps) {
        my $sub_deps = sub_deps();
        for my $dep (keys %$sub_deps) {
            $rev_deps{$_}->{direct}->{$dep} = 1 for keys %{$sub_deps->{$dep}};
        }
        for my $dep (keys %$sub_deps) {
            $rev_deps{$dep}->{indirect} = rev_deps_helper(\%rev_deps, $dep);
        }
    }
    return \%rev_deps;
}

sub update_changelog {
    my ($dep, $version, @reasons) = @_;
    my $cl = ".deps-update/$dep/CHANGELOG.md";
    return if not -f $cl;
    my $reason = join "\n", map {"* $_"} @reasons;
    my $content = slurp($cl);
    if (not $content =~ /^# Version $version/) {
        $content = "# Version $version\n\n$reason\n\n$content"
    } else {
        $content =~ s/(# Version $version\n\n)/$1$reason\n/;
    }
    write_file($cl, $content);
}

sub update_app_src {
    my ($dep, $version) = @_;
    my $app = ".deps-update/$dep/src/$dep.app.src";
    return if not -f $app;
    my $content = slurp($app);
    $content =~ s/({\s*vsn\s*,\s*)".*"/$1"$version"/;
    write_file($app, $content);
}

sub update_deps_versions {
    my ($config_path, %deps) = @_;
    my $config = slurp $config_path;

    for (keys %deps) {
        $config =~ s/(\{\s*$_\s*,\s*".*?"\s*,\s*\{\s*git\s*,\s*".*?"\s*,\s*)(?:{\s*tag\s*,\s*"(.*?)"\s*}|"(.*?)")/$1\{tag, "$deps{$_}"}/s;
    }

    write_file($config_path, $config);
}

sub cmp_ver {
    my @a = split /(\d+)/, $a;
    my @b = split /(\d+)/, $b;
    my $is_num = 1;

    return - 1 if $#a == 0;
    return 1 if $#b == 0;

    while (1) {
        my $ap = shift @a;
        my $bp = shift @b;
        $is_num = 1 - $is_num;

        if (defined $ap) {
            if (defined $bp) {
                if ($is_num) {
                    next if $ap == $bp;
                    return 1 if $ap > $bp;
                    return - 1;
                } else {
                    next if $ap eq $bp;
                    return 1 if $ap gt $bp;
                    return - 1;
                }
            } else {
                return 1;
            }
        } elsif (defined $bp) {
            return - 1;
        } else {
            return 0;
        }
    }
}

sub deps_git_info {
    state %info;
    if (not %info) {
        my $deps = top_deps();
        for my $dep (keys %{$deps}) {
            my $dir = ".deps-update/$dep";
            my @tags = `git -C "$dir" tag`;
            chomp(@tags);
            @tags = sort cmp_ver @tags;
            my $last_tag = $tags[$#tags];
            my @new = `git -C $dir log --oneline $last_tag..origin/master`;
            my $new_tag = $last_tag;
            $new_tag =~ s/(\d+)$/$1+1/e;
            chomp(@new);
            $info{$dep} = { last_tag => $last_tag, new_commits => \@new, new_tag => $new_tag };
        }
    }
    return { %info, %info_updates };
}

sub show_commands {
    my %commands = @_;
    my @keys;
    while (@_) {
        push @keys, shift;
        shift;
    }
    for (@keys) {
        say color("red"), $_, color("reset"), ") $commands{$_}";
    }
    ReadMode(4);
    while (1) {
        my $key = ReadKey(0);
        if (defined $commands{uc($key)}) {
            ReadMode(0);
            say "";
            return uc($key);
        }
    }
}

sub schedule_operation {
    my ($type, $dep, $tag, $reason, $op) = @_;

    my $idx = first { $operations[$_]->{dep} eq $dep } 0..$#operations;

    if (defined $idx) {
        my $mop = $operations[$idx];
        if (defined $op) {
            my $oidx = first { $mop->{operations}->[$_]->[0] eq $op->[0] } 0..$#{$mop->{operations}};
            if (defined $oidx) {
                $mop->{reasons}->[$oidx] = $reason;
                $mop->{operations}->[$oidx] = $op;
            } else {
                push @{$mop->{reasons}}, $reason;
                push @{$mop->{operations}}, $op;
            }
        }
        return if $type eq "update";
        $mop->{type} = $type;
        $info_updates{$dep}->{new_commits} = [];
        return;
    }

    my $info = deps_git_info();

    $top_deps_updates{$dep} = {commit => $tag};
    $info_updates{$dep} = {last_tag => $tag, new_tag => $tag,
        new_commits => $type eq "tupdate" ? [] : $info->{$dep}->{new_commits}};

    my $rev_deps = rev_deps();
    @operations = sort {
        exists $rev_deps->{$a->{dep}}->{indirect}->{$b->{dep}} ? -1 :
            exists $rev_deps->{$b->{dep}}->{indirect}->{$a->{dep}} ? 1 : $a->{dep} cmp $b->{dep}
    } (@operations, {
            type => $type,
            dep => $dep,
            version => $tag,
            reasons => ($reason ? [$reason] : []),
            operations => ($op ? [$op] : [])}
    );

    my $sub_deps = sub_deps();

    for (keys %{$rev_deps->{$dep}->{direct}}) {
        schedule_operation("update", $_, $info->{$_}->{new_tag}, "Updating $dep to version $tag.", [$dep, $tag]);
        $sub_deps_updates{$_} = $sub_deps_updates{$_} || clone($sub_deps->{$_});
        $sub_deps_updates{$_}->{$dep}->{commit} = $tag;
    }
}

sub git_tag {
    my ($dep, $ver, $msg) = @_;

    system("git", "-C", ".deps-update/$dep", "commit", "-a", "-m", $msg);
    system("git", "-C", ".deps-update/$dep", "tag", $ver);
}

sub git_push {
    my ($dep) = @_;
    system("git", "-C", ".deps-update/$dep", "push");
    system("git", "-C", ".deps-update/$dep", "push", "--tags");
}

update_deps_repos();

while (1) {
    my $top_deps = top_deps();
    my $git_info = deps_git_info();
    print color("bold blue"), "Dependences with newer tags:\n", color("reset");
    my $old_deps = 0;
    for my $dep (sort keys %$top_deps) {
        next unless $git_info->{$dep}->{last_tag} ne $top_deps->{$dep}->{commit};
        say color("red"), "$dep", color("reset"), ": $top_deps->{$dep}->{commit} -> $git_info->{$dep}->{last_tag}";
        $old_deps = 1;
    }
    say "(none)" if not $old_deps;
    say "";

    print color("bold blue"), "Dependences that have commits after last tags:\n", color("reset");
    my $changed_deps = 0;
    for my $dep (sort keys %$top_deps) {
        next unless @{$git_info->{$dep}->{new_commits}};
        say color("red"), "$dep", color("reset"), " ($top_deps->{$dep}->{commit}):";
        say "  $_" for @{$git_info->{$dep}->{new_commits}};
        $changed_deps = 1;
    }
    say "(none)" if not $changed_deps;
    say "";

    my $cmd = show_commands($old_deps ? (U => "Update dependency") : (),
        $changed_deps ? (T => "Tag new release") : (),
        @operations ? (A => "Apply changes") : (),
        E => "Exit");
    last if $cmd eq "E";

    if ($cmd eq "U") {
        while (1) {
            my @deps_to_update;
            my @od;
            my $idx = 1;
            for my $dep (sort keys %$top_deps) {
                next unless $git_info->{$dep}->{last_tag} ne $top_deps->{$dep}->{commit};
                $od[$idx] = $dep;
                push @deps_to_update, $idx++, "Update $dep to $git_info->{$dep}->{last_tag}";
            }
            last if $idx == 1;
            my $cmd = show_commands(@deps_to_update, E => "Exit");
            last if $cmd eq "E";

            my $dep = $od[$cmd];
            schedule_operation("update", $dep, $git_info->{$dep}->{last_tag});

            $top_deps = top_deps();
            $git_info = deps_git_info();
        }
    }

    if ($cmd eq "T") {
        while (1) {
            my @deps_to_tag;
            my @od;
            my $idx = 1;
            for my $dep (sort keys %$top_deps) {
                next unless @{$git_info->{$dep}->{new_commits}};
                $od[$idx] = $dep;
                push @deps_to_tag, $idx++, "Tag $dep with version $git_info->{$dep}->{new_tag}";
            }
            last if $idx == 1;
            my $cmd = show_commands(@deps_to_tag, E => "Exit");
            last if $cmd eq "E";

            my $dep = $od[$cmd];
            my $d = $git_info->{$dep};
            schedule_operation("tupdate", $dep, $d->{new_tag});

            $top_deps = top_deps();
            $git_info = deps_git_info();
        }
    }

    if ($cmd eq "A") {
        $top_deps = top_deps();
        $git_info = deps_git_info();
        my $sub_deps = sub_deps();

        for my $dep (keys %$top_deps) {
            for my $sdep (keys %{$sub_deps->{$dep}}) {
                next if not defined $top_deps->{$sdep} or
                    $sub_deps->{$dep}->{$sdep}->{commit} eq $top_deps->{$sdep}->{commit};
                say "$dep $sdep ",$sub_deps->{$dep}->{$sdep}->{commit}," <=> $sdep ",$top_deps->{$sdep}->{commit};
                schedule_operation("update", $dep, $git_info->{$dep}->{new_tag},
                    "Updating $sdep to version $top_deps->{$sdep}->{commit}.", [$sdep, $top_deps->{$sdep}->{commit}]);
            }
        }

        %info_updates = ();
        %top_deps_updates = ();
        %sub_deps_updates = ();

        $top_deps = top_deps();
        $git_info = deps_git_info();
        $sub_deps = sub_deps();

        print color("bold blue"), "List of operations:\n", color("reset");
        for my $op (@operations) {
            print color("red"), $op->{dep}, color("reset"), " ($top_deps->{$op->{dep}}->{commit} -> $op->{version})";
            if (@{$op->{operations}}) {
                say ":";
                say "  $_->[0] -> $_->[1]" for @{$op->{operations}};
            } else {
                say "";
            }
        }

        say "";
        my $cmd = show_commands(A => "Apply", E => "Exit");
        if ($cmd eq "A") {
            my %top_changes;
            for my $op (@operations) {
                update_changelog($op->{dep}, $op->{version}, @{$op->{reasons}})
                    if @{$op->{reasons}};
                update_deps_versions(".deps-update/$op->{dep}/rebar.config", unpairs(@{$op->{operations}}))
                    if @{$op->{operations}};
                if ($git_info->{$op->{dep}}->{last_tag} ne $op->{version}) {
                    update_app_src($op->{dep}, $op->{version});
                    git_tag($op->{dep}, $op->{version}, "Release $op->{version}");
                }

                $top_changes{$op->{dep}} = $op->{version};
            }
            update_deps_versions("rebar.config", %top_changes);
            for my $op (@operations) {
                if ($git_info->{$op->{dep}}->{last_tag} ne $op->{version}) {
                    git_push($op->{dep});
                }
            }
            last;
        }
    }
}
