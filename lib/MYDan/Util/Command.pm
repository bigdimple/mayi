package MYDan::Util::Command;
use strict;
use warnings;
use Carp;
use MYDan;

sub new
{
    my ( $class, $name, $cmd, $alias ) = @_;
    bless +{ name => $name, cmd => $cmd, alias => $alias || +{} }, ref $class || $class;
}

sub do
{
    my ( $this, $cmd, @argv )= @_;

    $ENV{MYDan_DEBUG} = 1 && $cmd = lc( $cmd ) if $cmd && $cmd =~ /^[A-Z][a-z]*$/;

    $cmd = $this->{alias}{$cmd} if $cmd && $this->{alias}{$cmd};

    my ( $c ) = grep{ $cmd && $_->[0] eq $cmd }@{$this->{cmd}};

    $this->help() and return unless $c;

    map{ exec join( ' ', "$MYDan::PATH/$_", map{"'$_'"}@argv ) if -e "$MYDan::PATH/$_" }splice @$c, 2;
    print "$cmd is not installed\n";
}

sub help
{
    my $this = shift;

    my ( $name, $cmd ) = @$this{qw( name cmd )};

    print "Usage: $name COMMAND [arg...]\n\nCommands:\n";

    map{
        my $x = grep{ -e "$MYDan::PATH/$_" }splice @$_, 2;
	if( $ENV{MYDan_DEBUG} )
	{
            printf "\t%s $_->[0]\t$_->[1]\n", $x ? $x =~ /^dan/ ? 'dan' : 'box' : 'nil';
	}
	else
	{
            printf "\t%s $_->[0]\t$_->[1]\n", $x ? '*': ' ';
	}
    }@$cmd;

    print "\nRun '$name COMMAND --help' for more information on a command.\n"
}

1;
__END__
