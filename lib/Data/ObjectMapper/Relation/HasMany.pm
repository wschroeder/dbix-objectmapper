package Data::ObjectMapper::Relation::HasMany;
use strict;
use warnings;
use base qw(Data::ObjectMapper::Relation);

sub get {
    my $self = shift;
    $self->get_multi(@_);
}

sub relation_condition {
    my $self = shift;
    my $class_table = shift;
    my $table = shift;
    my $rel_table = $self->mapper->table;

    my $fk = $rel_table->get_foreign_key_by_table( $class_table );

    my @cond;
    for my $i ( 0 .. $#{$fk->{keys}} ) {
        push @cond,
            $table->c( $fk->{keys}->[$i] )
                == $class_table->c($fk->{refs}->[$i]);
    }

    return @cond;
}

sub is_multi { 1 }

1;