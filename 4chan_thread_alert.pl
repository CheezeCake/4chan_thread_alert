#!/usr/bin/env perl

use strict;

use DBI;
use WWW::Mechanize;
use JSON;
use Getopt::Std;
use Error qw(:try);


sub help()
{
    print 'options:', "\n",
    ' -c config.json', "\n",
    '[-d databaseFile]', "\n",
    '[-k] : keep threads in database after 404', "\n",
    '[-h] : display this help', "\n";
    exit
}


use constant NMA_API_KEY => '';
use constant DB_DEFAULT => '/tmp/4chan_thread_alert.db';
use constant DRIVER => 'SQLite';


# parse command line
our $opt_c;
our $opt_d;
our $opt_h;
our $opt_k;
getopts('c:d:kh');


help() if (defined $opt_h);

# json config file
(defined $opt_c) or die 'No config specified';
(-e $opt_c) or die $opt_c.' : no such file';

# db file path
my $DB = (defined $opt_d) ? $opt_d : DB_DEFAULT;


# connect to db and create table if it does not exists
my $dbh = DBI->connect(
    'DBI:'.DRIVER.':dbname='.$DB, '', '', { RaiseError => 1 })
    or die $DBI::errstr;
my $stmt = qq(create table if not exists threads (board text not null, no text not null););
die $DBI::errstr if ($dbh->do($stmt) < 0);


# create browser
my $browser = WWW::Mechanize->new();


unless (defined $opt_k) {
    # select all entries
    my $stmt = qq(select board, no from threads;);
    my $sth = $dbh->prepare($stmt);
    my $rv = $sth->execute() or die $DBI::errstr;
    die $DBI::errstr if ($rv < 0);

    # remove the thread from the table if it is archived
    while (my @row = $sth->fetchrow_array()) {
        my $board = $row[0];
        my $no = $row[1];
        my $thread = 'https://a.4cdn.org/'.$board.'/thread/'.$no.'.json';

        try {
            my $response = $browser->get($thread);

            if ($response->is_success and
                length($response->decoded_content) > 0) {
                my $json = decode_json($response->decoded_content);
                my $posts = ${$json}{'posts'};
                my $op = @$posts[0];

                if (exists ${$op}{'archived'} and ${$op}{'archived'} eq '1') {
                    $stmt = qq(delete from threads where board='$board' and no='$no';);
                    $rv = $dbh->do($stmt) or die $DBI::errstr;
                    print $DBI::errstr if ($rv < 0);
                }
            }
        }
        catch Error with {
        };
    }
}


# load config
open my $config, '<', $opt_c;
my $config_str = do { local $/; <$config> };
my $json_config = decode_json($config_str);

# foreach config boards
while ((my $board, my $searches) = each %$json_config) {
    # fetch catalog
    my $catalog = 'https://a.4cdn.org/'.$board.'/catalog.json';
    my $response = $browser->get($catalog);

    if ($response->is_success) {
        my @json = decode_json($response->decoded_content);
        my $array = $json[0];

        # foreach page in catalog
        foreach my $page (@$array) {
            my $thread_array = @{$page}{'threads'};

            # foreach thread in page
            foreach my $thread (@$thread_array) {
                # check if it matches the search terms
                foreach my $search (@$searches) {
                    # perform search on the subject and filename
                    if ((${$thread}{'sub'} =~ /$search/i or
                            ${$thread}{'com'} =~ /$search/i or
                            ${$thread}{'filename'} =~ /$search/i)) {
                        my $no = ${$thread}{'no'};
                        my $stmt = qq(select count(*) from threads where board='$board' and no='$no';);
                        my $sth = $dbh->prepare($stmt);
                        my $rv = $sth->execute() or die $DBI::errstr;
                        die $DBI::errstr if ($rv < 0);
                        my $row = $sth->fetch;
                        my $n =  @$row[0];

                        if ($n == 0) {
                            # send notification
                            my $rep = $browser->post('https://www.notifymyandroid.com/publicapi/notify', [
                                    'apikey' => NMA_API_KEY,
                                    'application' => '4chan_thread_alert',
                                    'content-type' => 'text/html',
                                    'url' => 'https://boards.4chan.org/'.$board.'/thread/'.$no,
                                    'event' => 'Thread alert : /'.$board.'/'.$no.' | '.$search,
                                    'description' => 'Sub: '.${$thread}{'sub'}."\n".${$thread}{'com'}
                                ]);

                            # print $rep->decoded_content, "\n\n" if ($rep->is_success);

                            # insert in db
                            $stmt = qq(insert into threads (board, no) values('$board', '$no'););
                            $dbh->do($stmt) or die $DBI::errstr;
                        }
                    }
                }
            }
        }
    }
    else {
        print STDERR 'Error fetching : ', $catalog, "\n";
    }
}

$dbh->disconnect();
