# Copyright (C) 2020 SUSE LLC
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, see <http://www.gnu.org/licenses/>.

package MirrorCache::Task::MirrorScan;
use Mojo::Base 'Mojolicious::Plugin';

use DateTime;
use Digest::MD5;
use Mojo::UserAgent;
use Mojo::Util ('trim');

sub register {
    my ($self, $app) = @_;
    $app->minion->add_task(mirror_scan => sub { _scan($app, @_) });
}

sub _scan {
    my ($app, $job, $path) = @_;

    my $schema = $app->schema;
    my $minion = $app->minion;

    my $localdir = $app->mc->root($path);
    my $localfiles = Mojo::File->new($localdir)->list->map( 'basename' )->to_array;
    my $folder = $schema->resultset('Folder')->find({path => $path});
    return undef unless $folder && $folder->id; # folder is not added to db yet
    # we collect max(dt) here to avoid race with new files added to DB
    my $latestdt = $schema->resultset('File')->find({folder_id => $folder->id}, {
        columns => [ { max_dt => { max => "dt" } }, ]
    })->get_column('max_dt');

    unless ($latestdt) {
        return $job->note(skip_reason => 'latestdt empty', folder_id => $folder->id);
    }
    my $folder_id = $folder->id;
    my @dbfiles = ();
    my %dbfileids = ();
    for my $file ($schema->resultset('File')->search({folder_id => $folder_id})) {
        my $basename = $file->name;
        next unless $basename && -f $localdir . $basename; # skip deleted files
        push @dbfiles, $basename;
        $dbfileids{$basename} = $file->id;
    }

    my $folder_on_mirrors = $schema->resultset('Server')->folder($folder->id);
    my $ua = Mojo::UserAgent->new;
    for my $folder_on_mirror (@$folder_on_mirrors) {
        my $server_id = $folder_on_mirror->{server_id};
        my $url = $folder_on_mirror->{url};
        my $promise = $ua->get_p($url)->then(sub {
            my $tx = shift;
            # return $schema->resultset('Server')->forget_folder($folder_on_mirror->{server_id}, $folder_on_mirror->{folder_diff_id}) if $tx->result->code == 404;
            # return undef if $tx->result->code == 404;

            return $app->emit_event('mc_mirror_probe_error', {mirror => $folder_on_mirror->{server_id}, url => "u$url", err => $tx->result->code}, $folder_on_mirror->{server_id}) if $tx->result->code > 299;

            my $dom = $tx->result->dom;
            my $ctx = Digest::MD5->new;
            my %mirrorfiles = ();

            for my $i (sort { $a->attr->{href} cmp $b->attr->{href} } $dom->find('a')->each) {
                my $href = $i->attr->{href};
                my $text = trim $i->text;
                if ($text eq $href && -f $localdir . $text) {
                    $ctx->add($href);
                    $mirrorfiles{$href} = 1;
                }
            }
            my $digest = $ctx->hexdigest;
            my $folder_diff = $schema->resultset('FolderDiff')->find({folder_id => $folder_id, hash => $digest});
            unless ($folder_diff) {
                my $guard = $app->minion->guard("create_folder_diff_${folder_id}_$digest" , 60);
                $folder_diff = $schema->resultset('FolderDiff')->find_or_new({folder_id => $folder_id, hash => $digest});
                unless($folder_diff->in_storage) {
                    $folder_diff->dt($latestdt);
                    $folder_diff->insert;
                    
                    foreach my $file (@$localfiles) {
                        next if $mirrorfiles{$file};
                        my $id = $dbfileids{$file};
                        $schema->resultset('FolderDiffFile')->create({folder_diff_id => $folder_diff->id, file_id => $id}) if $id;
                    }
                }
            }
            $job->note("hash$server_id" => $digest);
            # do nothing if diff_id is the same
            return undef if $folder_on_mirror->{folder_diff_id} && $folder_diff->id eq $folder_on_mirror->{folder_diff_id};

            # $schema->resultset('FolderDiffServer')->update_or_create_by_folder_id({folder_diff_id => $folder_diff->{id}, server_id => $folder_on_mirror->{server_id}});
            my $fds = $schema->resultset('FolderDiffServer')->find_or_new(server_id => $folder_on_mirror->{server_id});
            $fds->folder_diff_id($folder_diff->id);
            $fds->update_or_insert;
        })->catch(sub {
            my $err = shift;
            return $app->emit_event('mc_mirror_probe_error', {mirror => $folder_on_mirror->{server_id}, url => "u$url", err => $err}, $folder_on_mirror->{server_id});
        })->wait;
    }
    
    $app->emit_event('mc_mirror_scan_complete', {path => $path, tag => $folder->id});
}

1;
