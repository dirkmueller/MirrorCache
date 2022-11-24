# Copyright (C) 2020,2021 SUSE LLC
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

# inspired by Mojolicious-Plugin-RenderFile
package MirrorCache::WebAPI::Plugin::RenderFileFromMirror;
use Mojo::Base 'Mojolicious::Plugin';

use strict;
use warnings;

use POSIX;
use XML::Writer;
use DateTime;
use Mojo::File;
use Mojo::Date;
use Mojo::Util;
use Mojo::IOLoop::Subprocess;

sub register {
    my ($self, $app) = @_;
    $app->types->type(metalink => 'application/metalink+xml; charset=UTF-8');
    $app->types->type(meta4    => 'application/metalink4+xml; charset=UTF-8');
    $app->types->type(zsync    => 'application/x-zsync');

    $app->helper( 'mirrorcache.render_file' => sub {
        my ($c, $filepath, $dm, $file)= @_;
        my $root = $c->mc->root;
        my $f = Mojo::File->new($filepath);
        my $dirname = $f->dirname;
        my $realdirname = $root->realpath($f->dirname);
        $realdirname = $dirname unless $realdirname;
        my $basename = $f->basename;
        $basename = $file->{name} if $file;

        my $dirname_basename = $dirname->basename;
        my $subtree = $dm->root_subtree;
        return $root->render_file($dm, $filepath, 1) if $dm->must_render_from_root; # && $root->is_reachable;

        my $schema = $c->schema;
        my $folder = $schema->resultset('Folder')->find({path => $subtree . $dirname});
        my $folder_id;
        if ($folder) {
            $folder_id = $folder->id;
            $dm->folder_id($folder_id);
            $dm->folder_sync_last($folder->sync_last);
            $dm->folder_scan_last($folder->scan_last);
            my $need_update = 0;
            if (!$folder->wanted) {
                $need_update = 1;
            } else {
                my $diff = DateTime->now(time_zone => 'local')->subtract_datetime($folder->wanted->set_time_zone('local'));
                my $diff_days = $diff->in_units('days');
                $need_update = 1 if $diff_days > 13 || $diff->in_units('months') > 0;
            }
            $schema->resultset('Folder')->set_wanted($folder_id) if $need_update;
        }
        my $realfolder_id;
        if ($realdirname ne $dirname) {
            my $realfolder = $schema->resultset('Folder')->find({path => $realdirname});
            $realfolder_id = $realfolder->id if $realfolder;
        }
        if ($folder) {
            my $fldid = ($realfolder_id? $realfolder_id : $folder_id);

            my $x = '';
            $x = '.zsync' if  ($dm->zsync && !$dm->accept_zsync);

            if (!$dm->zsync) {
                $file = $schema->resultset('File')->find_with_hash($fldid, $basename, $x) unless $file;
            } elsif (!$dm->meta4 && !$dm->metalink) {
                $file = $schema->resultset('File')->find_with_zhash($fldid, $basename, $x);
            } else {
                $file = $schema->resultset('File')->find_with_hash_and_zhash($fldid, $basename, $x);
            }
        }
        if($file) {
            $dm->file_id($file->{id});
            $dm->file_age($file->{age});
        }
        my $country = $dm->country;
        my $region  = $dm->region;
        if (!$folder || !$file) {
            return $root->render_file($dm, $filepath . '.metalink')  if ($dm->metalink && !$file && !$dm->accept_metalink); # file is unknown - cannot generate metalink
            return $root->render_file($dm, $filepath . '.meta4')     if ($dm->meta4    && !$file && !$dm->accept_meta4); # file is unknown - cannot generate meta4
            return $root->render_file($dm, $filepath)
              if !$dm->extra || $dm->accept_all; # TODO we still can check file on mirrors even if it is missing in DB
        }

        if (!$folder || !$file) {
            return $c->render(status => 404, text => "File not found");
        }
        my $baseurl; # just hostname + eventual urldir (without folder and file)
        my $fullurl; # baseurl with path and filename
        if ($dm->metalink || $dm->meta4 || $dm->torrent || $dm->zsync || $dm->magnet) {
	    $baseurl = $root->is_remote ? $root->location($dm) : $root->redirect($dm, $folder->path) # we must pass $path here because it potenially has impact
        }
        if ($dm->torrent || $dm->zsync || $dm->magnet) {
            if ($baseurl) {
                $fullurl = $baseurl . '/' . $filepath;
            } else {
                ($fullurl = $c->req->url->to_abs->to_string) =~ s/\.(torrent|zsync|magnet)$//;
            }
	}

        if ($dm->btih) {
            _render_btih($c, $basename, $file);
            $c->stat->redirect_to_root($dm, 1);
            return 1;
        }
        if ($dm->magnet) {
            _render_magnet($c, $fullurl, $basename, $file);
            $c->stat->redirect_to_root($dm, 1);
            return 1;
        }

        my (@mirrors_country, @mirrors_region, @mirrors_rest);

        _collect_mirrors($dm, \@mirrors_country, \@mirrors_region, \@mirrors_rest, $file->{id}, $folder_id);

        # add mirrors that have realpath
        _collect_mirrors($dm, \@mirrors_country, \@mirrors_region, \@mirrors_rest, $file->{id}, $realfolder_id) if $realfolder_id;
        my $mirror;
        $mirror = $mirrors_country[0] if @mirrors_country;
        $mirror = $mirrors_region[0]  if !$mirror && @mirrors_region;
        $mirror = $mirrors_rest[0]    if !$mirror && @mirrors_rest;

        $dm->mirror_country($mirror->{country}) if $mirror;
        if ($dm->extra) {
            if ($mirror) {
                $c->stat->redirect_to_mirror($mirror->{mirror_id}, $dm);
            } else {
                $c->stat->redirect_to_root($dm);
            }
        }

        if ($dm->zsync && ($file->{zlengths} || !$dm->accept_all)) {
            _render_zsync($c, $fullurl, $basename, $file->{mtime}, $file->{size}, $file->{sha1}, $file->{zblock_size}, $file->{zlengths}, $file->{zhashes},
                           \@mirrors_country, \@mirrors_region, \@mirrors_rest);
            return 1;
        }

        if (($dm->metalink || $dm->meta4) && !($dm->accept_all && 'media.1/media' eq substr($filepath,length($filepath)-length('media.1/media')))) {
            my $origin;
            if (my $publisher_url = $ENV{MIRRORCACHE_METALINK_PUBLISHER_URL}) {
                $publisher_url =~ s/^https?:\/\///;
                $origin = $dm->scheme . '://' . $publisher_url;
            } else {
                my $originurl = $c->req->url->to_abs;
                $origin = $dm->scheme . '://' . $originurl->host;
                $origin = $origin . ":" . $originurl->port if $originurl->port && $originurl->port != "80";
                $origin = $origin . $dm->route;
            }
            $origin = $origin . $filepath;
            my $xml;
            if ($dm->meta4) {
                $xml = _build_meta4(
                    $dm, $folder->path, $file, $country, $region, \@mirrors_country, \@mirrors_region,
                    \@mirrors_rest, $origin, 'MirrorCache', $baseurl);
                $c->res->headers->content_disposition('attachment; filename="' .$basename. '.meta4"');
                $c->render(data => $xml, format => 'meta4');
                return 1;
            }
            $xml = _build_metalink(
                $dm, $folder->path, $file, $country, $region, \@mirrors_country, \@mirrors_region,
                \@mirrors_rest, $origin, 'MirrorCache', $baseurl);
            $c->res->headers->content_disposition('attachment; filename="' .$basename. '.metalink"');
            $c->render(data => $xml, format => 'metalink');
            return 1;
        }

        return _render_torrent($dm, $file, \@mirrors_country, \@mirrors_region, \@mirrors_rest, $fullurl) if $dm->torrent;

        if ($dm->mirrorlist) {
            my @mirrordata;
            if ($country and !$dm->avoid_countries || !(grep { $country eq $_ } $dm->avoid_countries)) {
                for my $m (@mirrors_country) {
                    push @mirrordata,
                      {
                        url      => $m->{url},
                        hostname => $m->{hostname},
                        location => uc($m->{country}),
                        lat      => $m->{lat},
                        lng      => $m->{lng},
                      };
                }
            }

            my @mirrordata_region;
            if ($region) {
                for my $m (@mirrors_region) {
                    push @mirrordata_region,
                      {
                        url      => $m->{url},
                        hostname => $m->{hostname},
                        location => uc($m->{country}),
                        lat      => $m->{lat},
                        lng      => $m->{lng},
                      };
                }
                @mirrordata_region = sort { $a->{location} cmp $b->{location} || $a->{url} cmp $b->{url} } @mirrordata_region;
            }

            my @mirrordata_rest;
            for my $m (@mirrors_rest) {
                push @mirrordata_rest,
                  {
                    url      => $m->{url},
                    hostname => $m->{hostname},
                    location => uc($m->{country}),
                    lat      => $m->{lat},
                    lng      => $m->{lng},
                  };
            }
            @mirrordata_rest = sort { $a->{location} cmp $b->{location} || $a->{url} cmp $b->{url} } @mirrordata_rest;
            return $c->render(json => {l1 => \@mirrordata, l2 => \@mirrordata_region, l3 => \@mirrordata_rest}) if ($dm->json);

            my $size = $file->{size};
            my $hsize = MirrorCache::Utils::human_readable_size($size) if defined $size;
            my $mtime = $file->{mtime};
            my $hmtime = strftime("%d-%b-%Y %H:%M:%S", gmtime($mtime)) if $mtime;
            my $fileorigin;
            my $fileoriginpath = $filepath;


            if ($ENV{MIRRORCACHE_METALINK_PUBLISHER_URL}) {
                $fileorigin = $ENV{MIRRORCACHE_METALINK_PUBLISHER_URL};
                $fileorigin = $dm->scheme . "://" . $fileorigin unless $fileorigin =~ m/^http/;
            } elsif ($root->is_remote) {
                $fileorigin = $root->location($dm);
            } else {
                my $redirect = $root->redirect($dm, $filepath);
                if ($redirect) {
                    $fileorigin = $redirect;
                    $fileoriginpath = $folder->path . '/' . $file->{name};
                } else {
                    my $url = $c->req->url->to_abs;
                    $fileorigin = $dm->scheme . '://' . $url->host;
                    $fileorigin = $fileorigin . ":" . $url->port if $url->port && $url->port != "80";
                    $fileorigin = $fileorigin . $dm->route;
                }
            }

            my $filedata = {
                url    => $fileorigin . $fileoriginpath,
                name   => $basename,
                size   => $size,
                hsize  => $hsize,
                mtime  => $mtime,
                hmtime => $hmtime,
                md5    => $file->{md5},
                sha1   => $file->{sha1},
                sha256 => $file->{sha256},
            };

            my @regions = $c->subsidiary->regions($region, $country);
            $c->stash('nonavbar' => 1) if ($ENV{MIRRORCACHE_BRANDING});
            $c->stash('mirrorlist' => 1);
            my ($lat, $lng) = $dm->coord;
            my $preferred_url = $mirror->{url} if $mirror && (0 == @regions);
            $c->render(
                'mirrorlist',
                cur_path          => $filepath,
                route             => $dm->route,
                file              => $filedata,
                preferred_url     => $preferred_url,
                mirrordata        => \@mirrordata,
                mirrordata_region => \@mirrordata_region,
                mirrordata_rest   => \@mirrordata_rest,
                country           => uc($country),
                region            => $region,
                ip                => $dm->ip,
                lat               => $lat,
                lng               => $lng,
                regions           => \@regions,
                scheme            => $dm->scheme,
            );
            return 1;
        }

        unless ($mirror) {
            $root->render_file($dm, $filepath);
            return 1;
        }

        unless ($dm->pedantic) {
            # Check below is needed only when MIRRORCACHE_ROOT_COUNTRY is set
            # only with remote root and when no mirrors should be used for the root's country
            if ($country ne $mirror->{country} && $dm->root_is_better($mirror->{region}, $mirror->{lng})) {
                return $root->render_file($dm, $filepath, 1);
            }
            my $url = $mirror->{url};
            $c->redirect_to($url);
            eval {
                $c->stat->redirect_to_mirror($mirror->{mirror_id}, $dm);
            };
            return 1;
        }

        my $tx = $c->render_later->tx;
        my $ua  = Mojo::UserAgent->new->connect_timeout(1)->request_timeout(2)->max_redirects(8);
        my $recurs1;
        my $expected_size  = $file->{size};
        my $expected_mtime = $file->{mtime};
        my $recurs = sub {
            my $prev = shift;

            return if $prev && ($prev == 200 || $prev == 302 || $prev == 301);
            my $mirror;
            if (@mirrors_country) {
                $mirror = shift @mirrors_country;
            }
            elsif (@mirrors_region) {
                $mirror = shift @mirrors_region;
            }
            elsif (@mirrors_rest) {
                $mirror = shift @mirrors_rest;
            }
            unless ($mirror) {
                return $root->render_file($dm, $filepath);
            }
            # Check below is needed only when MIRRORCACHE_ROOT_COUNTRY is set
            # only with remote root and when no mirrors should be used for the root's country
            if ($country ne $mirror->{country} && $dm->root_is_better($mirror->{region}, $mirror->{lng})) {
                $root->render_file($dm, $filepath, 1);
                return 1;
            }
            my $url = $mirror->{url};
            my $code;
            $ua->head_p($url, {'User-Agent' => 'MirrorCache/pedantic'})->then(sub {
                my $result = shift->result;
                $code = $result->code;
                if ($code == 200 || $code == 302 || $code == 301) {
                    my $size = $result->headers->content_length if $result->headers;
                    if ((defined $size && defined $expected_size) && ($size || $expected_size) && $size ne $expected_size) {
                        my $scan_last = $dm->folder_scan_last;
                        if ($scan_last && $expected_mtime && $expected_mtime < Mojo::Date->new($result->headers->last_modified)->epoch) {
                            if ($dm->scan_last_ago() > 15*60) {
                                $c->emit_event('mc_mirror_path_error', {e1 => $expected_mtime, e2 => Mojo::Date->new($result->headers->last_modified)->epoch, ago1 => $dm->scan_last_ago(), path => $dirname, code => $code, url => $url, folder => $folder->id, country => $dm->country, id => $mirror->{mirror_id}});
                            }
                            return $root->render_file($dm, $filepath, 0); # file on mirror is newer than we have
                        } elsif ($scan_last) {
                            if ($dm->scan_last_ago() > 24*60*60) {
                                $c->emit_event('mc_mirror_path_error', {ago2 => $dm->scan_last_ago(), path => $dirname, code => $code, url => $url, folder => $folder->id, country => $dm->country, id => $mirror->{mirror_id}});
                            }
                        } else {
                                $c->emit_event('mc_debug', {message => 'path error', path => $dirname, code => $code, url => $url, folder => $folder->id, country => $dm->country, id => $mirror->{mirror_id}});
                        }
                        $code = 409;
                        return undef;
                    }
                    $c->redirect_to($url);
                    $c->stat->redirect_to_mirror($mirror->{mirror_id}, $dm);
                    return 1;
                }
                if ($dm->sync_last_ago() > 4*60*60) {
                    $c->emit_event('mc_mirror_path_error', {path => $dirname, code => 200, url => $url, folder => $folder->id, country => $dm->country, id => $mirror->{mirror_id}});
                }
                if ($dm->scan_last_ago() > 4*60*60) {
                    $c->emit_event('mc_mirror_path_error', {path => $dirname, code => $code, url => $url, folder => $folder->id, country => $dm->country, id => $mirror->{mirror_id}});
                }
            })->catch(sub {
                $c->emit_event('mc_mirror_error', {path => $dirname, error => shift, url => $url, folder => $folder->id, id => $mirror->{mirror_id}});
            })->finally(sub {
                return $recurs1->($code);
                my $reftx = $tx;
            })->wait;
        };
        $recurs1 = $recurs;
        $recurs->();
    });

    return $app;
}

# metalink should not include root url in mirror list if mirror count exceeds METALINK_GREEDY parameter
my $METALINK_GREEDY = int( $ENV{MIRRORCACHE_METALINK_GREEDY} // 0 ) // 0;
my $publisher = $ENV{MIRRORCACHE_METALINK_PUBLISHER} || 'openSUSE';
my $publisher_url = $ENV{MIRRORCACHE_METALINK_PUBLISHER_URL} || 'http://download.opensuse.org';


sub _build_meta4() {
    my (
        $dm,             $path,         $file,   $country,   $region, $mirrors_country,
        $mirrors_region, $mirrors_rest, $origin, $generator, $rooturl
    ) = @_;
    my $basename = $file->{name};
    $country = uc($country) if $country;
    $region  = uc($region)  if $region;

    my $writer = XML::Writer->new(OUTPUT => 'self', DATA_MODE => 1, DATA_INDENT => 2, );
    $writer->xmlDecl('UTF-8');
    $writer->startTag('metalink', xmlns => 'urn:ietf:params:xml:ns:metalink');
    $writer->dataElement( generator => $generator ) if $generator;
    $writer->dataElement( origin    => $origin, dynamic => 'true') if $origin;
    $writer->dataElement( published => strftime('%Y-%m-%dT%H:%M:%SZ', localtime time));

    $writer->startTag('publisher');
    $writer->dataElement( name => $publisher    ) if $publisher;
    $writer->dataElement( url  => $publisher_url) if $publisher_url;
    $writer->endTag('publisher');

    $writer->startTag('file', name => $basename);
    $writer->dataElement( size => $file->{size} ) if $file->{size};
    $writer->comment('<mtime>' . $file->{mtime} . '</mtime>') if ($file->{mtime});
    if (my $md5 = $file->{md5}) {
        $writer->startTag('hash', type => 'md5');
        $writer->characters($md5);
        $writer->endTag('hash');
    }
    if (my $sha1 = $file->{sha1}) {
        $writer->startTag('hash', type => 'sha-1');
        $writer->characters($sha1);
        $writer->endTag('hash');
    }
    if (my $sha256 = $file->{sha256}) {
        $writer->startTag('hash', type => 'sha-256');
        $writer->characters($sha256);
        $writer->endTag('hash');
    }
    if (my $piece_size = $file->{piece_size}) {
        $writer->startTag('pieces', length => $piece_size, type => 'sha-1');
        for my $piece (grep {$_} split /(.{40})/, $file->{pieces}) {
            $writer->dataElement( hash => $piece );
        }
        $writer->endTag('pieces');
    }

    my $priority = 1;
    my $fullname = $path . '/' . $basename;
    my $root_included = 0;
    my $print_root = sub {
        return unless $rooturl;

        my $print = shift;
        return if $root_included and !$print;

        $writer->comment("File origin location: ") if $print;
        if ($METALINK_GREEDY && $METALINK_GREEDY <= $priority) {
            $writer->comment($rooturl . $fullname);
        } else {
            $writer->startTag('url', location => uc($dm->root_country), priority => $priority);
            $writer->characters($rooturl . $fullname);
            $writer->endTag('url');
        }
        $root_included = 1;
        $priority++;
    };
    $writer->comment("Mirrors which handle this country ($country): ");
    for my $m (@$mirrors_country) {
        my $url = $m->{url};

        $print_root->() if $country ne uc($m->{country}) && $dm->root_is_better($m->{region}, $m->{lng});
        $writer->startTag('url', location => uc($m->{country}), priority => $priority);
        $writer->characters($url);
        $writer->endTag('url');
        $priority++;
    }
    $print_root->() if $dm->root_country eq lc($country);

    $writer->comment("Mirrors in the same continent ($region): ");
    for my $m (@$mirrors_region) {
        my $url   = $m->{url};

        $print_root->() if $dm->root_is_better($m->{region}, $m->{lng});
        $writer->startTag(
                    'url',
                    location => uc($m->{country}),
                    priority => $priority
                );
        $writer->characters($url);
        $writer->endTag('url');
        $priority++;
    }
    $print_root->() if $dm->root_is_hit;

    $writer->comment("Mirrors in other parts of the world: ");
    for my $m (@$mirrors_rest) {
        my $url   = $m->{url};
        $print_root->() if $dm->root_is_better($m->{region}, $m->{lng});
        $writer->startTag(
                    'url',
                    location => uc($m->{country}),
                    priority => $priority
                );
        $writer->characters($url);
        $writer->endTag('url');
        $priority++;
    }

    $print_root->(1);
    $writer->endTag('file');
    $writer->endTag('metalink');

    return $writer->end();
}

sub _build_metalink() {
    my (
        $dm,             $path,         $file,   $country,   $region, $mirrors_country,
        $mirrors_region, $mirrors_rest, $origin, $generator, $rooturl
    ) = @_;
    my $basename = $file->{name};
    $country = uc($country) if $country;
    $region  = uc($region)  if $region;

    my $writer = XML::Writer->new(OUTPUT => 'self', DATA_MODE => 1, DATA_INDENT => 2, );
    $writer->xmlDecl('UTF-8');
    my @attribs = (
        version => '3.0',
        xmlns => 'http://www.metalinker.org/',
        type => 'dynamic',
    );
    push @attribs, (origin => "$origin.metalink") if $origin;
    push @attribs, (generator => $generator) if $generator;
    push @attribs, (pubdate => strftime("%Y-%m-%d %H:%M:%S %Z", localtime time));

    $writer->startTag('metalink', @attribs);

    $writer->startTag('publisher');
    $writer->dataElement( name => $publisher    ) if $publisher;
    $writer->dataElement( url  => $publisher_url) if $publisher_url;
    $writer->endTag('publisher');

    $writer->startTag('files');
    {
        $writer->startTag('file', name => $basename);
        $writer->dataElement( size => $file->{size} ) if $file->{size};
        $writer->comment('<mtime>' . $file->{mtime} . '</mtime>') if ($file->{mtime});
        my $md5 = $file->{md5};
        my $sha1 = $file->{sha1};
        my $sha256 = $file->{sha256};
        if ($md5 || $sha1 || $sha256) {
            $writer->startTag('verification');
            if ($md5) {
                $writer->startTag('hash', type => 'md5');
                $writer->characters($md5);
                $writer->endTag('hash');
            }
            if ($sha1) {
                $writer->startTag('hash', type => 'sha-1');
                $writer->characters($sha1);
                $writer->endTag('hash');
            }
            if ($sha256) {
                $writer->startTag('hash', type => 'sha-256');
                $writer->characters($sha256);
                $writer->endTag('hash');
            }
            if (my $piece_size = $file->{piece_size}) {
                $writer->startTag('pieces', length => $piece_size, type => 'sha-1');
                my $piecen = 0;
                for my $piece (grep {$_} split /(.{40})/, $file->{pieces}) {
                    $writer->dataElement( hash => $piece, piece => $piecen);
                    $piecen++;
                }
                $writer->endTag('pieces');
            }
            $writer->endTag('verification');
        }

        my $colon = $rooturl ? index(substr($rooturl,0,6),':') : '';
        $writer->startTag('resources');
        {
            my $preference = 100;
            my $fullname = $path . '/' . $basename;
            my $root_included = 0;
            my $print_root = sub {
                return unless $rooturl;

                my $print = shift;
                return if $root_included and !$print;

                $writer->comment("File origin location: ") if $print;
                if ($METALINK_GREEDY && $METALINK_GREEDY <= (100 - $preference)) {
                    $writer->comment($rooturl . $fullname);
                } else {
                    $writer->startTag('url', type => substr($rooturl,0,$colon), location => uc($dm->root_country), preference => $preference);
                    $writer->characters($rooturl . $fullname);
                    $writer->endTag('url');
                }
                $root_included = 1;
                $preference--;
            };
            $writer->comment("Mirrors which handle this country ($country): ");
            for my $m (@$mirrors_country) {
                my $url = $m->{url};
                my $colon = index(substr($url,0,6), ':');
                next unless $colon > 0;

                $print_root->() if $country ne uc($m->{country}) && $dm->root_is_better($m->{region}, $m->{lng});
                $writer->startTag('url', type => substr($url,0,$colon), location => uc($m->{country}), preference => $preference);
                $writer->characters($url);
                $writer->endTag('url');
                $preference--;
            }
            $print_root->() if $dm->root_country eq lc($country);

            $writer->comment("Mirrors in the same continent ($region): ");
            for my $m (@$mirrors_region) {
                my $url   = $m->{url};
                my $colon = index(substr($url, 0, 6), ':');
                next unless $colon > 0;

                $print_root->() if $dm->root_is_better($m->{region}, $m->{lng});
                $writer->startTag(
                    'url',
                    type       => substr($url, 0, $colon),
                    location   => uc($m->{country}),
                    preference => $preference
                );
                $writer->characters($url);
                $writer->endTag('url');
                $preference--;
            }
            $print_root->() if $dm->root_is_hit;

            $writer->comment("Mirrors in other parts of the world: ");
            for my $m (@$mirrors_rest) {
                my $url   = $m->{url};
                my $colon = index(substr($url, 0, 6), ':');
                next unless $colon > 0;

                $print_root->() if $dm->root_is_better($m->{region}, $m->{lng});
                $writer->startTag(
                    'url',
                    type       => substr($url, 0, $colon),
                    location   => uc($m->{country}),
                    preference => $preference
                );
                $writer->characters($url);
                $writer->endTag('url');
                $preference--;
            }

            $print_root->(1);
        }
        $writer->endTag('resources');
        $writer->endTag('file');
    }
    $writer->endTag('files');
    $writer->endTag('metalink');

    return $writer->end();
}

sub _collect_mirrors {
    my ($dm, $mirrors_country, $mirrors_region, $mirrors_rest, $file_id, $folder_id) = @_;

    my $country = $dm->country;
    my $region  = $dm->region;
    my $scheme  = $dm->scheme;
    my $ipv = $dm->ipv;
    my $vpn = $dm->vpn;
    my ($lat, $lng) = $dm->coord;
    my $avoid_countries = $dm->avoid_countries;
    my $mirrorlist = $dm->mirrorlist;
    my $ipvstrict  = $dm->ipvstrict;
    my $metalink   = $dm->metalink || $dm->meta4 || $dm->zsync;
    my $limit = $mirrorlist ? 100 : (( $metalink || $dm->pedantic )? 10 : 1);
    my $rs = $dm->c->schemaR->resultset('Server');

    my $m;
    $m = $rs->mirrors_query(
            $country, $region,  $folder_id, $file_id,        $scheme,
            $ipv,     $lat, $lng,    $avoid_countries, $limit,      0,
            !$mirrorlist, $ipvstrict, $vpn
    ) if $country;

    push @$mirrors_country, @$m if $m && scalar(@$m);
    my $found_count = scalar(@$mirrors_country) + scalar(@$mirrors_region) + scalar(@$mirrors_rest);

    if ($region && (($found_count < $limit))) {
        my @avoid_countries;
        push @avoid_countries, @$avoid_countries if $avoid_countries && scalar(@$avoid_countries);
        push @avoid_countries, $country if ($country and !(grep { $country eq $_ } @avoid_countries));
        $m = $rs->mirrors_query(
            $country, $region,  $folder_id, $file_id,       $scheme,
            $ipv,     $lat, $lng,    \@avoid_countries, $limit,     0,
            !$mirrorlist, $ipvstrict, $vpn
        );
        my $found_more;
        $found_more = scalar(@$m) if $m;
        if ($found_more) {
            $found_count += $found_more;
            push @$mirrors_region, @$m;
        }
    }

    if (
        ($found_count < $limit && !$dm->root_country) ||
        ($metalink && $found_count < 3) ||
        $mirrorlist
    ) {
        $m = $rs->mirrors_query(
            $country, $region,  $folder_id, $file_id,          $scheme,
            $ipv,  $lat, $lng,    $avoid_countries, $limit,  1,
            !$mirrorlist, $ipvstrict, $vpn
        );
        my $found_more;
        $found_more = scalar(@$m) if $m;
        if ($found_more) {
            $found_count += $found_more;
            push @$mirrors_rest, @$m;
        }
    }
    for $m (@$mirrors_country, @$mirrors_region, @$mirrors_rest) {
        $m->{url} = $m->{scheme} . '://' . $m->{hostname} . $m->{uri};
    }
    return $found_count;
}

sub _render_zsync() {
    my ($c, $url, $filename, $mtime, $size, $sha1, $zblock_size, $zlengths, $zhash, $mirrors_country, $mirrors_region, $mirrors_rest) = @_;

    unless($zhash) {
        $c->render(status => 404, text => "File not found");
        return 1;
    }

    my $header = <<"EOT";
zsync: 0.6.2-mirrorcache
Filename: $filename
MTime: $mtime
Blocksize: $zblock_size
Length: $size
Hash-Lengths: $zlengths
EOT

    for my $m (@$mirrors_country, @$mirrors_region, @$mirrors_rest) {
        $header = $header . "URL: $m->{url}\n";
    }
    $header = $header . "URL: $url\n";
    $header = $header . "SHA-1: $sha1\n\n";

    $c->res->headers->content_length(length($header) + length ($zhash));
    $c->res->headers->content_type('application/x-zsync');
    $c->write($header => sub () {
            $c->write($zhash => sub () {$c->finish});
        });

    return 1;
}

sub _render_btih() {
    my ($c, $filename, $file) = @_;

    unless($file->{md5}) {
        $c->render(status => 404, text => "File not found");
        return 1;
    }

    $c->render(text => "$filename " . _calc_btih($filename, $file));
    return 1;
}

sub _render_magnet() {
    my ($c, $url, $filename, $file) = @_;

    unless($file->{piece_size}) {
        $c->render(status => 404, text => "File not found");
        return 1;
    }

    my $btih  = _calc_btih($filename, $file);
    my $md5   = $file->{md5};
    my $size  = $file->{size};
    $filename = Mojo::Util::url_escape($filename);
    $url      = Mojo::Util::url_escape($url);

    $c->render(text => "magnet:?xt=urn:btih:$btih&amp;xt=urn:md5:$md5&amp;xl=$size&amp;dn=$filename&amp;as=$url");
    return 1;
}

sub _render_torrent() {
    my ($dm, $file, $mirrors_country, $mirrors_region, $mirrors_rest, $url) = @_;

    my $c = $dm->c;

    unless($file->{piece_size}) {
        $c->render(status => 404, text => "File not found");
        return 1;
    }

    my $tracker     = $ENV{MIRRORCACHE_TRACKER} // 'http://tracker.opensuse.org:6969/announce';
    my $trackerlen  = length($tracker);
    my $filename    = $file->{name};
    my $filenamelen = length($filename);
    my $size        = $file->{size};
    my $mtime       = $file->{mtime};
    my $md5         = $file->{md5};
    my $piece_size  = $file->{piece_size};
    my $sha1        = pack 'H*', $file->{sha1};
    my $sha256      = pack 'H*', $file->{sha256};
    my $pieces      = pack 'H*', $file->{pieces};

    my $header = "d8:announce$trackerlen:$tracker" .
                 "13:announce-listll$trackerlen:${tracker}ee" .
                 "7:comment$filenamelen:$filename" .
                 "10:created by11:MirrorCache13:creation datei${mtime}e" .
                 "4:infod6:lengthi${size}e" .
                 "6:md5sum32:$md5" .
                 "4:name$filenamelen:$filename" .
                 "12:piece lengthi${piece_size}e" .
                 "6:pieces" . length($pieces) . ":";

    my $footer = "4:sha120:$sha1" .
                 "6:sha25632:${sha256}e" .
                 "7:sourcesl";
    if (scalar(@$mirrors_country) > 0 || scalar(@$mirrors_region) > 0 || scalar(@$mirrors_rest) > 0) {
        for my $m (@$mirrors_country, @$mirrors_region, @$mirrors_rest) {
            $footer = $footer . length($m->{url}) . ":" . $m->{url};
        }
    } else {
        $footer = $footer . length($url) . ":" . $url;
    }
    $footer = $footer . 'ee';

    $c->res->headers->content_length(length($header) + length($pieces) + length($footer));
    $c->write($header => sub () {
            $c->write($pieces => sub () {
                $c->write($footer => sub () {$c->finish});
            })
        });

    return 1;
}

sub _calc_btih() {
    my ($filename, $file) = @_;

    my $sha1 = Digest::SHA->new(1);
    $sha1->
        add('d')->
        add('6:lengthi:' . $file->{size})->
        add('6:md5sum32:' . $file->{md5})->
        add('4:name' . length($filename) . ":$filename")->
        add('12:piece lengthi:' . $file->{piece_size})->
        add('6:pieces:' . length($file->{pieces}))->add($file->{pieces})->
        add('4:sha120:' . $file->{sha1})->
        add('6:sha25632:' . $file->{sha256})->
        add('e');

    return $sha1->hexdigest;
}

1;
