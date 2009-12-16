use strict;
use warnings;
use Test::More qw(no_plan);
use Test::Exception;

use Data::ObjectMapper::Engine;
use Data::ObjectMapper::Engine::DBI;
use DBI;
use List::MoreUtils;
use Data::ObjectMapper::Log;
use Try::Tiny;

my $log = Data::ObjectMapper::Log->new();

{ # basic
    check_interface('Data::ObjectMapper::Engine');
    check_interface('Data::ObjectMapper::Engine::DBI');
};

{ # dbi-sqlite
    dies_ok{ Data::ObjectMapper::Engine::DBI->new() };

    ok my $dr = Data::ObjectMapper::Engine::DBI->new(
        [
            'DBI:SQLite:',
            undef,
            undef,
            {},
            [
                q{CREATE TABLE test1 (id integer primary key, t text, key1 interger, key2 integer, UNIQUE(key1, key2) )}
            ]
        ]
    );
    $dr->log( $log );
    ok $dr->dbh;

    ok my $dr2 = Data::ObjectMapper::Engine::DBI->new({
        dsn => 'DBI:SQLite:',
        username => undef,
        password => undef,
        on_connect_do => [
            q{CREATE TABLE test1 (id integer primary key, t text)}
        ],
    });
    $dr2->log( $log );
    ok $dr2->dbh;

    # get_primary_key
    is_deeply [ $dr->get_primary_key() ], [ 'id' ];

    # get_column_info
    my @columns = map{ $_->{name} } @{$dr->get_column_info('test1')};
    my %defind_columns = (
        id => 1,
        t => 1,
        key1 => 1,
        key2 => 1,
    );
    ok List::MoreUtils::all{ $defind_columns{$_} } @columns;

    # get_unique_key
    my @keys = @{$dr->get_unique_key('test1')->[0][1]};
    my %uniq_keys = ( key1 => 1, key2 => 1);
    ok List::MoreUtils::all{ $uniq_keys{$_} } @keys;

    # insert
    is_deeply { id => 1, t => 'texttext', key1 => 1, key2 => 1 },
        $dr->insert(
        {   table  => 'test1',
            values => {
                t    => 'texttext',
                key1 => 1,
                key2 => 1,
            },
        },
        undef,
        ['id']
        ),
        'insert';

    # update
    ok $dr->update({
        table => 'test1',
        set => { key1 => 2, key2 => 2 },
        where => [ [ 'id', 1 ] ],
    });

    # select_single
    is_deeply [qw(1 texttext 2 2)], $dr->select_single({
        from => 'test1',
        where => [ [ 'id', 1 ] ],
    });

    # select
    my $it = $dr->select({
        from => 'test1',
        where => [ [ 'id', 1 ] ],
    });
    is_deeply [qw(1 texttext 2 2)], $it->next;

    # delele
    ok $dr->delete({ table => 'test1', where => [ [ 'id', 1 ]] });

    ok !$dr->select_single({
        from => 'test1',
        where => [ [ 'id', 1 ] ],
    });


    # transaction
    $dr->transaction(
        sub{
            my $res = $dr->insert(
                $dr->query->insert->table('test1')->values(
                    t => 'texttext2',
                    key1 => 3,
                    key2 => 3,
                ),
                ['id']
            )
        }
    );

    ok $dr->select_single({
        from => 'test1',
        where => [ [ 'id', 1 ] ],
    });


    # rollback
    try {
        $dr->transaction(
            sub{
                my $res2 = $dr->insert({
                    table => 'test1',
                    values => {
                        t => 'texttext3',
                        key1 => 4,
                        key2 => 4,
                    },
                }, ['id']);
                die "died!";
            }
        );
    } catch {
        ok ~/died!/;
    };

    ok !$dr->select_single({
        from => 'test1',
        where => [ [ 'id', 2 ] ],
    });

    # txn_do
    dies_ok { $dr->transaction };

    $dr->transaction(
        sub{
            $dr->insert({
                table => 'test1',
                values => {
                    t => 'texttext_txn_do',
                    key1 => 5,
                    key2 => 5,
                },
            },['id']);
            $dr->insert({
                table => 'test1',
                values => {
                    t => 'texttext_txn_do',
                    key1 => 6,
                    key2 => 6,
                },
            }, ['id']);
        }
    );

    is_deeply [ [qw(2 5 5)], [qw(3 6 6)] ], [ $dr->select({
        column => [qw(id key1 key2)],
        from => 'test1',
        where => [ [ 't', 'texttext_txn_do' ] ],
    })->all ];


    # txn_do fail
    {
        local $@;
        try {
            $dr->transaction(
                sub{
                    $dr->delete({ table => 'test1', where => [ [ 'id', 1 ]] });
                    $dr->insert({
                        table => 'test2',
                        values => {
                            t => 'texttext_txn_do_fail',
                            key1 => 7,
                            key2 => 7,
                        },
                    }, ['id']);
                }
            );
        } catch {
            ok $_, $_;
        };
    };

    ok $dr->select_single({
        from => 'test1',
        where => [ [ 'id', 1 ] ],
    });

};

sub check_interface {
    my $pkg = shift;
    for(
        'new',
        '_init',
        'transaction',
        'namesep',
        'datetime_parser',
        'get_primary_key',
        'get_column_info',
        'get_unique_key',
        'select',
        'select_single',
        'update',
        'insert',
        'delete',
        'stm_debug',
        'log',
    ) {
        ok $pkg->can($_), "$pkg can $_";
    }
}
