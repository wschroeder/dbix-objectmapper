package DBIx::ObjectMapper::Mapper::Instance;
use strict;
use warnings;
use Carp::Clan;
use Try::Tiny;
use Scalar::Util qw(refaddr weaken);
use Log::Any qw($log);
use DBIx::ObjectMapper::Utils;

my %INSTANCES;
my %STATUS = (
    # "status" => "changable status"
    transient  => [ 'pending', 'persistent', 'detached' ],
    pending    => [ 'expired', 'detached' ],
    persistent => [ 'expired', 'detached' ],
    detached   => [],
    expired    => [ 'persistent', 'detached' ],
);

sub new {
    my ( $class, $instance ) = @_;
    return $class->get(refaddr($instance)) || $class->create($instance);
}

sub create {
    my ( $class, $instance ) = @_;

    my $self = bless {
        instance            => $instance,
        status              => 'transient',
        is_modified         => 0,
        modified_data       => +{},
        unit_of_work        => undef,
        identity_condition  => undef,
        relation_condition  => +{},
        primary_cache_key   => undef,
        unique_cache_keys   => [],
        save_many_to_many   => [],
        remove_many_to_many => [],
    }, $class;
    $INSTANCES{refaddr($instance)} = $self;
    $self->initialize;
    return $self;
}

sub instances { %INSTANCES }

sub initialize {
    my $self = shift;
    $self->init_identity_condition;
    $self->init_relation_identity_condition;
    $self->init_cache_keys;
}

sub init_identity_condition {
    my $self = shift;
    my $record = shift || $self->reducing;
    my $class_mapper = $self->instance->__class_mapper__;
    my $identity_condition
        = +[ map { $class_mapper->table->c($_) == $record->{$_} }
            @{ $class_mapper->table->primary_key } ];

    if( @$identity_condition ) {
        return $self->{identity_condition} = $identity_condition;
    }
    elsif( my $unique_key = @{ $class_mapper->table->unique_key } ) {
        for my $uniq ( @$unique_key ) {
            return $self->{identity_condition} = map {
                $class_mapper->table->c($_) == $record->{$_} } @{$uniq->[1]};
        }
    }

    confess "Can't define identity.";
}

sub identity_condition { $_[0]->{identity_condition} }

sub init_relation_identity_condition {
    my $self = shift;
    my $record = shift || $self->reducing;
    my $class_mapper = $self->instance->__class_mapper__;

    for my $prop_name ( $class_mapper->attributes->property_names ) {
        my $prop = $class_mapper->attributes->property($prop_name);
        next unless $prop->type eq 'relation';
        my @cond = $prop->{isa}->identity_condition($self);
        next unless @cond;
        $self->{relation_condition}->{$prop_name} = \@cond;
    }
}

sub relation_condition { $_[0]->{relation_condition} }

sub init_cache_keys {
    my $self = shift;
    my $result = shift || $self->reducing;
    my $class_mapper = $self->instance->__class_mapper__;
    $self->{primary_cache_key} = $class_mapper->primary_cache_key($result);
    $self->{unique_cache_keys} = [ $class_mapper->unique_cache_keys($result) ];
}

sub cache_keys {
    my $self = shift;
    return ( $self->primary_cache_key, $self->unique_cache_keys );
}

sub primary_cache_key { $_[0]->{primary_cache_key} }
sub unique_cache_keys { @{$_[0]->{unique_cache_keys}} }

sub get {
    my ( $self, $addr ) = @_;
    $INSTANCES{$addr};
}

sub unit_of_work { $_[0]->{unit_of_work} }
sub status       { $_[0]->{status} }

sub change_status {
    my $self = shift;
    my $status_name = shift;
    return if $self->status eq $status_name;

    if ( $STATUS{$status_name}
        and grep { $_ eq $status_name } @{$STATUS{ $self->status }} )
    {
        $self->{status} = $status_name;
        if( $status_name eq 'persistent' || $status_name eq 'pending' ) {
            unless( $self->unit_of_work ) {
                my $uow = shift ||  confess "need UnitOfWork";
                $self->{unit_of_work} = $uow;
            }
        }
        elsif( $status_name eq 'detached' ) {
            my $class_mapper = $self->instance->__class_mapper__;
            for my $prop_name ( $class_mapper->attributes->property_names ) {
                my $prop = $class_mapper->attributes->property($prop_name);
                next unless $prop->type eq 'relation';
                if( $prop->{isa}->is_cascade_detach() ) {
                    if( my $instance = $self->instance->{$prop_name} ) {
                        my @instance
                            = ref $instance eq 'ARRAY'
                            ? @$instance
                            : ($instance);
                        $self->unit_of_work->detach($_) for @instance;
                    }
                }
            }
        }
        elsif( $status_name eq 'expired' ) {
            my $class_mapper = $self->instance->__class_mapper__;
            for my $prop_name ( $class_mapper->attributes->property_names ) {
                my $prop = $class_mapper->attributes->property($prop_name);
                next unless $prop->type eq 'relation';
                if( $prop->{isa}->is_cascade_reflesh_expire() ) {
                    if( my $instance = $self->instance->{$prop_name} ) {
                        my @instance
                            = ref $instance eq 'ARRAY'
                                ? @$instance
                                    : ($instance);
                        for ( @instance ) {
                            my $mapper = $_->__mapper__;
                            if (   $mapper->is_pending
                                || $mapper->is_persistent )
                            {
                                $mapper->change_status('expired');
                            }
                        }
                    }
                }
            }
        }
        else {
            #warn $status_name;
        }
    }
    else {
        confess "Can't change status : " . $self->status . " => $status_name";
    }
}

sub is_transient  { $_[0]->status eq 'transient' }
sub is_persistent { $_[0]->status eq 'persistent' }
sub is_detached   { $_[0]->status eq 'detached' }
sub is_pending    { $_[0]->status eq 'pending' }
sub is_expired    { $_[0]->status eq 'expired' }

sub instance { $_[0]->{instance} }

sub reducing {
    my ( $self ) = @_;
    my %result;
    my $class_mapper = $self->instance->__class_mapper__;
    my %primary_key = map { $_ => 1 } @{$class_mapper->table->primary_key};
    for my $prop_name ( $class_mapper->attributes->property_names ) {
        my $prop = $class_mapper->attributes->property($prop_name);
        next unless $prop->type eq 'column';
        my $col_name = $prop->name;
        unless ( $primary_key{$col_name}
            and !defined $self->instance->{$prop_name} )
        {
            $result{$col_name} = $self->instance->{$prop_name};
        }
    }
    return \%result;
}

sub reflesh {
    my $self = shift;
    my $class_mapper = $self->instance->__class_mapper__;
    my ( $key, @cond )
        = $class_mapper->get_unique_condition( $self->identity_condition );
    my $new_val = $class_mapper->table->_find(@cond) || return;

    $self->change_status('persistent');
    $self->unit_of_work->_set_cache($self);
    $self->modify( $new_val );

    for my $prop_name ( $class_mapper->attributes->property_names ) {
        my $prop = $class_mapper->attributes->property($prop_name);
        next unless $prop->type eq 'relation';
        if( $prop->{isa}->is_cascade_reflesh_expire() ) {
            if( my $instance = $self->instance->{$prop_name} ) {
                my @instance
                    = ref $instance eq 'ARRAY'
                        ? @$instance
                            : ($instance);
                $_->__mapper__->reflesh for @instance;
            }
        }
    }
}

sub modify {
    my $self = shift;
    my $rdata = shift;
    my $class_mapper = $self->instance->__class_mapper__;
    for my $prop_name ( $class_mapper->attributes->property_names ) {
        my $col = $class_mapper->attributes->property($prop_name)->name
            || $prop_name;
        $self->instance->{$prop_name} = $rdata->{$col} if exists $rdata->{$col};
    }

    return $self->instance;
}

sub get_val_trigger {
    my ( $self, $name ) = @_;

    my $class_mapper = $self->instance->__class_mapper__;
    my $prop = $class_mapper->attributes->property($name);

    if( $self->is_expired ) {
        $self->reflesh;
    }
    elsif( !$self->is_persistent ) {
        $self->instance->{$name} = []
            if !defined $self->instance->{$name} and $prop->is_multi;
        return;
    }

    if( $prop->type eq 'relation' ) {
        $self->load_rel_val($name)
            if !defined $self->instance->{$name}
                or ( ref $self->instance->{$name} eq 'ARRAY'
                    and @{ $self->instance->{$name} } == 0 );
    }
    elsif( my %lazy_column = $class_mapper->attributes->lazy_column($name) ) {
        unless ( defined $self->instance->{$name} ) {
            my $uniq_cond = $self->identity_condition;
            my $val
                = $class_mapper->table->select->column( values %lazy_column )
                ->where(@$uniq_cond)->first;
            $self->unit_of_work->{query_cnt}++;
            $self->instance->{$_} = $val->{ $_ } for keys %lazy_column;
        }
    }

    $self->demolish if $self->is_transient;
}

sub load_rel_val {
    my $self = shift;
    my $name = shift;
    my $class_mapper = $self->instance->__class_mapper__;
    $class_mapper->attributes->property($name)->get( $name, $self );
}

sub set_val_trigger {
    my ( $self, $name, $val ) = @_;

    if( $self->status eq 'expired' ) {
        $self->reflesh;
    }

    my $class_mapper = $self->instance->__class_mapper__;
    my $prop = $class_mapper->attributes->property($name);
    if ( my $meth = $prop->validation_method ) {
        $self->instance->${meth}($val);
    }
    elsif ( my $code = $prop->validation ) {
        unless ( $code->(@_) ) {
            confess "parameter $name is invalid.";
        }
    }

    if ($self->is_persistent
        and !DBIx::ObjectMapper::Utils::is_deeply(
            $self->instance->{$name}, $val
        )
    ) {
        $self->{is_modified} = 1;
        $self->{modified_data}->{ $prop->name } = $val;
    }

    $self->demolish if $self->is_transient;
    return;
}

sub is_modified   { $_[0]->{is_modified} }
sub modified_data { $_[0]->{modified_data} }

sub update {
    my ( $self ) = @_;
    confess 'it need to be "persistent" status.' unless $self->is_persistent;

    my $reduce_data = $self->reducing;
    my $modified_data = $self->modified_data;
    my $uniq_cond = $self->identity_condition;
    my $class_mapper = $self->instance->__class_mapper__;

    my $result;
    try {
        my $new_val;
        if( keys %$modified_data ) {
            $result = $class_mapper->table->update->set(%$modified_data)
                ->where(@$uniq_cond)->execute();
            $new_val = DBIx::ObjectMapper::Utils::merge_hashref(
                $reduce_data,
                $modified_data
            );
        }

        for my $prop_name ( $class_mapper->attributes->property_names ) {
            my $prop = $class_mapper->attributes->property($prop_name);
            next unless $prop->type eq 'relation';
            if( $prop->{isa}->is_cascade_save_update() ) {
                $prop->{isa}->cascade_update( $prop_name, $self );
            }
        }

        for my $smm ( @{$self->{save_many_to_many}} ) {
            my $prop = $class_mapper->attributes->property($smm->{name});
            next unless $prop->type eq 'relation';
            $prop->{isa}->many_to_many_add(
                $smm->{name},
                $self,
                $self->get($smm->{mapper_addr})->instance,
            );
        }

        for my $rmm ( @{$self->{remove_many_to_many}} ) {
            my $prop = $class_mapper->attributes->property($rmm->{name});
            next unless $prop->type eq 'relation';
            $prop->{isa}->many_to_many_remove(
                $rmm->{name},
                $self,
                $self->get($rmm->{mapper_addr})->instance,
            );
        }

        $self->modify($new_val) if $new_val;
        $self->{is_modified} = 0;
        $self->{modified_data} = +{};
    } catch {
        $self->change_status('detached');
        confess @_;
    };

    $self->change_status('expired'); # cascade expire if cascade_reflesh_expire
    return !$result || $self->instance;
}

sub save {
    my ( $self ) = @_;

    confess 'it need to be "pending" status.' unless $self->is_pending;
    my $reduce_data = $self->reducing;
    my $class_mapper = $self->instance->__class_mapper__;
    my $data = { %$reduce_data, %{$class_mapper->default_value} };

    try {
        my $comp_result
            = $class_mapper->table->insert->values(%$data)->execute();
        $self->modify($comp_result);
        $self->initialize;

        for my $prop_name ( $class_mapper->attributes->property_names ) {
            my $prop = $class_mapper->attributes->property($prop_name);
            next unless $prop->type eq 'relation';

            if( $prop->{isa}->is_cascade_save_update() ) {
                if( my $instance = $self->instance->{$prop_name} ) {
                    for ( ref $instance eq 'ARRAY' ? @$instance : $instance ) {
                        $prop->{isa}->cascade_save($prop_name, $self, $_ );
                    }
                }
            }
        }
    } catch {
        $self->change_status('detached');
        confess @_;
    };

    $self->change_status('expired');
    return $self->instance;
}

sub delete {
    my $self = shift;
    confess 'it need to be "persistent" status.' unless $self->is_persistent;
    my $uniq_cond = $self->identity_condition;
    my $class_mapper = $self->instance->__class_mapper__;

    my $result;
    try {
        for my $prop_name ( $class_mapper->attributes->property_names ) {
            my $prop = $class_mapper->attributes->property($prop_name);
            next unless $prop->type eq 'relation';
            if( $prop->{isa}->is_cascade_delete() ) {
                if( my $instance = $self->instance->{$prop->name} ) {
                    my @instance
                        = ref $instance eq 'ARRAY' ? @$instance : ($instance);
                    $self->unit_of_work->detach($_) for @instance;
                }
                $prop->{isa}->cascade_delete($self);
            }
        }

        $result = $class_mapper->table->delete->where(@$uniq_cond)->execute();
    } catch {
        $self->change_status('detached');
        confess @_;
    };

    $self->change_status('detached');
    return $result;
}

sub add_multi_val {
    my $self = shift;
    my $name = shift;
    my $obj  = shift;

    my $class_mapper = $self->instance->__class_mapper__;
    my $prop = $class_mapper->attributes->property($name) || return;
    return unless $prop->type eq 'relation';

    if ( $prop->{isa}->type eq 'many_to_many'
        and ( $obj->__mapper__->is_transient || $obj->__mapper__->is_pending )
        )
    {
        my $mapper_addr = refaddr($obj);
        $self->_regist_many_to_many_event( $name, $mapper_addr, 'save' );
    }
    else {
        $self->unit_of_work->add($obj);
    }
}

sub remove_multi_val {
    my $self = shift;
    my $name = shift;
    my $obj  = shift;

    my $class_mapper = $self->instance->__class_mapper__;
    my $prop = $class_mapper->attributes->property($name) || return;

    return unless $prop->type eq 'relation';

    if (    $prop->{isa}->type eq 'many_to_many'
        and $obj->__mapper__->is_persistent )
    {
        my $mapper_addr  = refaddr($obj);
        $self->_regist_many_to_many_event($name, $mapper_addr, 'remove');
    }
    else {
        $self->unit_of_work->delete($obj);
    }
}

sub _regist_many_to_many_event {
    my $self = shift;
    my ($name, $mapper_addr, $event) = @_;
    $self->{is_modified} = 1;
    push @{$self->{$event . '_many_to_many'}}, {
        name => $name,
        mapper_addr => $mapper_addr,
    };
}

sub demolish {
    my $self = shift;
    my $id = refaddr($self->instance) || return;
    $self->{unit_of_work} = undef;
    delete $INSTANCES{$id} if exists $INSTANCES{$id};
}

sub DESTROY {
    my $self = shift;
    $self->demolish;
    warn "DESTROY $self" if $ENV{MAPPER_DEBUG};
}

1;