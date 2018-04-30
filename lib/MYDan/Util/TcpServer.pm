package MYDan::Util::TcpServer;

use warnings;
use strict;
use Carp;

use Data::Dumper;

use Tie::File;
use Fcntl 'O_RDONLY';
use POSIX ":sys_wait_h";
use Time::HiRes qw(time);
use AnyEvent;
use AnyEvent::Impl::Perl;
use AnyEvent::Socket;
use AnyEvent::Handle;
use Fcntl qw(:flock SEEK_END);
use Filesys::Df;

use MYDan;

my ( %index, %w );

sub new
{
    my ( $class, %this ) = @_;

    map{ die "$_ unkown" unless $this{$_} && $this{$_} =~ /^\d+$/ }
        qw( port max ReservedSpaceCount ReservedSpaceSize );

    $0 = 'mydan.tcpserver.'.$this{port};

    die "no file:$this{'exec'}\n" unless $this{'exec'} && -e $this{'exec'};

    map{ 
        $this{$_} ||= "$MYDan::PATH/var/run/tcpserver.$this{port}/$_";
        system( "mkdir -p '$this{$_}'" ) unless -d $this{$_};
        map{ unlink $_ if $_ =~ /\/\d+$/ || $_ =~ /\/\d+\.out$/ || $_ =~ /\/\d+\.ext$/ }glob "$this{$_}/*";
     }qw( tmp ReservedSpace );


    my ( $c, $s, $r ) = map{ $this{$_} }qw( ReservedSpaceCount ReservedSpaceSize ReservedSpace );
    $c = $this{max} if $c > $this{max};

    open my $H, '>', "$r/tmp" or die "Can't open '$r/tmp': $!";
    map{ print $H "\0" x 1024; } 1 .. $s;
    close $H;

    for my $i ( 1 .. $c )
    {
        map{ system "cp '$r/tmp' '$r/$i$_'"; }('', '.out');
    }

    map{ $this{$_} ||= $this{buf} }qw( rbuf wbuf );

    bless \%this, ref $class || $class;
}

sub run
{
    my $this = shift;
    my ( $port, $max, $exec, $tmp, $rbuf, $wbuf ) = @$this{qw( port max exec tmp rbuf wbuf )};

    my $version = $MYDan::VERSION; $version =~ s/\./0/g;

    $SIG{'USR1'} = sub {
        print Dumper \%index, \%w;
    };

    $SIG{INT} = $SIG{TERM} = sub { 
        map{ kill 'TERM', $_->{pid} if $_->{pid}; }values %index;
        die "kill.\n";
    };

    $SIG{'CHLD'} = sub {
        while((my $pid = waitpid(-1, WNOHANG)) >0)
        {
            my $code = ( $? == -1 || $? & 127 ) ? 110 : $? >> 8;

            
            print "chld: $pid exit $code.\n";;

            my ( $index ) = grep{ $index{$_}{pid}  && $index{$_}{pid} eq $pid  }keys %index;
            next unless my $data = delete $index{$index};


            if( $data->{handle}->fh )
            {
                $data->{handle}->push_write( "*#*MYDan_$version*#" );

                my $size = $wbuf ? ( stat "$tmp/$index.out" )[7] || 0 : 0;

                if ( ( ! $wbuf || ( $wbuf && $size <= $wbuf ) ) && open my $tmp_handle, '<', "$tmp/$index.out" )
                {
			$w{$index} = +{ code => $code, handle => $data->{handle}, fh => $tmp_handle };
                }
            }

	    map{ unlink "$tmp/$_" if -e "$tmp/$_" }( $index, "$index.out", "$index.ext" );
        }
    };

    my ( $i, $cv ) = ( 0, AnyEvent->condvar );

    my $whitelist;
   
    tcp_server undef, $port, sub {
       my ( $fh, $tip, $tport ) = @_ or die "tcp_server: $!";

       printf "index: %s\n", ++ $i;
       my $index = $i;

       my $len = keys %index;
       printf "tcpserver: status: $len/$max\n";

       if( $this->{whitelist} && ! $whitelist->{$tip} )
       {
           printf "connection not allow, from %s:%s\n", $tip, $tport;
           close $fh;   
           return;
       }


       if( $len >= $max )
       {
           printf "connection limit reached, from %s:%s\n", $tip, $tport;
           close $fh;   
           return;
       }

       my $tmp_handle;

       if( $this->dfok() )
       {
           unless( open $tmp_handle, '>', "$tmp/$index" )
           {
	       print "open '$tmp/$index' fail:$!\n";
               close $fh;
               return;
           }
       }
       else
       {
           my $rs = $this->space();
           unless( $rs ) { close $fh; return; }

           map{ system "ln '$this->{ReservedSpace}/$rs$_' '$tmp/$index$_'" }( '', '.out' );
           unless( open $tmp_handle, '+<', "$tmp/$index" )
           {
	       print "open '$tmp/$index' fail:$!\n";
               map{ unlink "$tmp/$rs$_" if -e "$tmp/$rs$_" }( '', '.out' );
               close $fh;
               return;
           }
       }

       my $EF;
       my $handle; $handle = new AnyEvent::Handle( 
           fh => $fh,
           keepalive => 1,
           on_eof => sub{
               close $tmp_handle;

               if ( my $pid = fork() )
               {
                   $index{$index}{pid} = $pid;
               }
               else
               {
    	           $tip = '0.0.0.0' unless $tip && $tip =~ /^\d+\.\d+\.\d+\.\d+$/;
                   $tport = '0' unless $tport && $tport =~ /^\d+$/;

                   $ENV{TCPREMOTEIP} = $tip;
                   $ENV{TCPREMOTEPORT} = $port;
		   $ENV{MYDanExtractFile} = "$tmp/$index.ext" if defined $index{$index}{extsize};
      
                   open STDIN, '<', "$tmp/$index" or die "Can't open '$tmp/$index': $!";
                   my $m = -f "$tmp/$index.out" ? '+<' : '>';
                   open STDOUT, $m, "$tmp/$index.out" or die "Can't open '$tmp/$index.out': $!";
                   $ENV{UseReservedSpace} = 1 if $m eq '+<';
                   exec $exec;
               }
           },
           on_read => sub {
               my $self = shift;

	       if( ! $index{$index}{rbuf} && $self->{rbuf} =~ s/^MYDanExtractFile_::(\d+)::_MYDanExtractFile// )
	       {
		   $index{$index}{extsize} = $1;
                   open $EF, ">$tmp/$index.ext" or die "Can't open $tmp/$index.ext";
		   $index{$index}{rbuf} = 1;
	       }

	       my $len = length $self->{rbuf};
	       if( $index{$index}{extsize} )
	       {
		   if( $len < $index{$index}{extsize} )
		   {
                       $self->push_read (
                           chunk => $len,
			   sub { print $EF $_[1] }
		       );
		       $index{$index}{extsize} -= $len;
		       $len = 0;
		   }
		   else
		   {
                       $self->push_read(
			    chunk => $index{$index}{extsize},
			   sub { print $EF $_[1]}
		       );
		       $len -= $index{$index}{extsize};
                       $index{$index}{extsize} = 0;
		   }
	       }


	       if( $len )
	       {
                   $index{$index}{rbuf} += $len;
                   $self->push_read (
                       chunk => $len,
                       sub { print $tmp_handle $_[1] if ! $rbuf || ( $rbuf && $index{$index}{rbuf} <= $rbuf ); }
                   );
               }
            },
            on_error => sub {
               close $tmp_handle;

               close $fh;
               delete $handle->{fh};

               $handle->destroy();

               my $pid = $index{$index}{pid} if $index{$index};
               if( $pid ) { kill 15, $pid; }
               else
               {
		    map{ unlink "$tmp/$_" if -e "$tmp/$_" }( $index, "$index.out", "$index.ext" );
               }
            },
        );
       $index{$index}{handle} = $handle;
    
    };

    my $ww = AnyEvent->timer(
        after => 0.01, 
        interval => 0.05,
        cb => sub { 
            for my $index ( keys %w )
            {
            	my ( $data, $buf, $n ) = $w{$index};
            
            	map{
            	    if( $n = sysread( $data->{fh}, $buf, 102400 ) && $data->{handle}->fh )
            	    {
		        if( ! $data->{body} && $buf =~ s/MYDanExtractFile_::(.+)::_MYDanExtractFile// )
			{
                            $data->{file} = $1;
			}
			$data->{body} = 1;
            	        $data->{handle}->push_write($buf);
            	    }
            	    else{
		        close $data->{fh};
		        if( my $f = delete $data->{file} )
			{
                             if( open my $tmp_handle, '<', $f )
			     {
			         $data->{fh} = $tmp_handle;
			     }
			     else
			     {
			         warn "open MYDanExtractFile fail: $!";
			     }
			}
			else
			{
                            $data->{handle}->push_write("--- $data->{code}\n") if $data->{handle}->fh;
                            $data->{handle}->destroy() if $data->{handle}->fh;
                            delete $w{$index};
                            next;
			}
            	    }
            	}1..10;
            }
        }
    ); 

    my $t = AnyEvent->timer(
        after => 1, 
        interval => 1,
        cb => sub { 
            map{ 
                $_->{handle}->push_write('*') if $_->{handle} && $_->{handle}->fh;
            }values %index; 
        }
    ); 

    my $mtime = 0;
    my $wl = AnyEvent->timer(
        after => 1, 
        interval => 30,
        cb => sub { 
            if( -f $this->{whitelist} )
            {
                my ( $mt, @ip ) = ( stat $this->{whitelist} )[9];
                return if $mtime == $mt;
                unless( tie @ip, 'Tie::File', $this->{whitelist}, mode => O_RDONLY )
                {
                    print "tie fail: $!\n";
                    return;
                }
                $whitelist = +{ map{ $_ => 1 }@ip };
                $mtime = $mt;
            }

        }
    ) if $this->{whitelist}; 
 
    $cv->recv;
}

sub space
{
    my $path = shift->{ReservedSpace};

    for ( glob "$path/*" )
    {
        next unless $_ =~ /\/(\d+)$/;
        my $id = $1;

        next unless rsok( $_ ) && rsok( "$_.out" );
        map{ system "cp '$path/tmp' '$path/$id$_'" }( '', '.out' );
        return $id;
    }
    return undef;
}

sub rsok
{
    my $file = shift;
    return ( $file && -f $file && ( stat $file )[3] == 1 ) ? 1 : 0;
}

sub dfok
{
    my $F;
    unless ( open( $F, shift->{tmp} ) )
    {
        print "df open tmp fail\n";
        return undef;
    }

    my $df = df($F);
    close $F;

    return undef unless $df && ref $df eq 'HASH' && defined $df->{bfree} && defined $df->{ffree};
    return ( $df->{bfree} > 102400 && $df->{ffree} > 4000 ) ? 1 : 0;
}

1;
