
program coupler_main

!-----------------------------------------------------------------------
!
!   program that couples component models for the atmosphere,
!   ocean (amip), land, and sea-ice using the exchange module
!
!-----------------------------------------------------------------------

!--- F90 module for OpenMP
use omp_lib

!--- model component modules
use atmos_model_mod,    only: atmos_model_init, atmos_model_end, &
                              update_atmos_model_dynamics,       &
                              update_atmos_model_radiation,      &
                              update_atmos_model_down,           &
                              update_atmos_model_up,             &
                              update_atmos_model_state,          &
                              atmos_data_type,                   &
                              land_ice_atmos_boundary_type

use land_model_mod,     only: land_model_init, land_model_end, &
                              update_land_model_fast,          &
                              update_land_model_slow,          &
                              land_data_type,                  &
                              atmos_land_boundary_type

use ice_model_mod,      only: ice_model_init, ice_model_end,  &
                              update_ice_model_fast,          &
                              update_ice_model_slow,          &
                              ice_data_type,                  &
                              atmos_ice_boundary_type
                             !land_ice_boundary_type

!--- FMS modules
use constants_mod,      only: constants_init

use data_override_mod,  only: data_override_init

use diag_manager_mod,   only: diag_manager_init, diag_manager_end, &
                              get_base_date, diag_manager_set_time_end

use field_manager_mod,  only: MODEL_ATMOS, MODEL_LAND, MODEL_ICE

use flux_exchange_mod,  only: flux_exchange_init,   &
                              sfc_boundary_layer,   &
                              flux_down_from_atmos, &
                              flux_up_to_atmos,     &
                              flux_exchange_end       ! may not be used?

use fms_affinity_mod,   only: fms_affinity_init, fms_affinity_set

use fms_mod,            only: open_namelist_file, file_exist, check_nml_error,  &
                              error_mesg, fms_init, fms_end, close_file,        &
                              write_version_number, uppercase, stdout

use fms_io_mod,         only: fms_io_exit

use mpp_mod,            only: mpp_init, mpp_pe, mpp_root_pe, mpp_npes, mpp_get_current_pelist, &
                              stdlog, mpp_error, NOTE, FATAL, WARNING
use mpp_mod,            only: mpp_clock_id, mpp_clock_begin, mpp_clock_end

use mpp_mod,            only: mpp_chksum, mpp_set_current_pelist

use mpp_domains_mod,    only: mpp_get_global_domain, mpp_global_field, CORNER, mpp_set_domain_symmetry

use mpp_io_mod,         only: mpp_open, mpp_close, &
                              MPP_NATIVE, MPP_RDONLY, MPP_DELETE

use time_manager_mod,   only: time_type, set_calendar_type, set_time,  &
                              set_date, days_in_month, month_name,     &
                              operator(+), operator (<), operator (>), &
                              operator (/=), operator (/), get_date,   &
                              operator (*), THIRTY_DAY_MONTHS, JULIAN, &
                              GREGORIAN, NOLEAP, NO_CALENDAR

use tracer_manager_mod, only: tracer_manager_init, get_tracer_index, &
                              get_number_tracers, get_tracer_names,  &
                              NO_TRACER

implicit none

!-----------------------------------------------------------------------

  character(len=128) :: version = 'unknown'
  character(len=128) :: tag = 'FMSCoupler_SIMPLE'

!-----------------------------------------------------------------------
!---- model defined-types ----

 type (atmos_data_type) :: Atm
 type  (land_data_type) :: Land
 type   (ice_data_type) :: Ice

 type(atmos_land_boundary_type)     :: Atmos_land_boundary
 type(atmos_ice_boundary_type)      :: Atmos_ice_boundary
 type(land_ice_atmos_boundary_type) :: Land_ice_atmos_boundary

!-----------------------------------------------------------------------
!---- storage for fluxes ----

 real, allocatable, dimension(:,:)   ::                         &
    t_surf_atm, albedo_atm, land_frac_atm, dt_t_atm, dt_q_atm,  &
    flux_u_atm, flux_v_atm, dtaudv_atm, u_star_atm, b_star_atm, &
    rough_mom_atm

!-----------------------------------------------------------------------
! ----- coupled model time -----

   type (time_type) :: Time_atmos, Time_init, Time_end,  &
                       Time_step_atmos, Time_step_ocean
   integer :: num_cpld_calls, num_atmos_calls, nc, na

! ----- coupled model initial date -----

   integer :: date_init(6)
   integer :: calendar_type = -99

! ----- timing flags -----

   integer :: initClock, mainClock, termClock
   integer, parameter :: timing_level = 1

!-----------------------------------------------------------------------

   integer, dimension(6) :: current_date = (/ 0, 0, 0, 0, 0, 0 /)
   character(len=17) :: calendar = '                 '
   logical :: force_date_from_namelist = .false.  ! override restart values for date
   integer :: months=0, days=0, hours=0, minutes=0, seconds=0
   integer :: dt_atmos = 0
   integer :: dt_ocean = 0
   integer :: atmos_nthreads = 1

   logical :: do_chksum = .FALSE.  !! If .TRUE., do multiple checksums throughout the execution of the model.
   logical :: do_land = .FALSE. !! If true, will call update_land_model_fast
   logical :: use_hyper_thread = .false.

   namelist /coupler_nml/ current_date, calendar, force_date_from_namelist, &
                          months, days, hours, minutes, seconds,            &
                          dt_atmos, dt_ocean, atmos_nthreads,               &
                          do_chksum, do_land, use_hyper_thread

!#######################################################################

   call fms_init()
   call mpp_init()
   initClock = mpp_clock_id( 'Initialization' )
   mainClock = mpp_clock_id( 'Main loop' )
   termClock = mpp_clock_id( 'Termination' )
   call mpp_clock_begin (initClock)
  
   call fms_init
   call constants_init
   call fms_affinity_init

   call coupler_init
   if (do_chksum) call coupler_chksum('coupler_init+', 0)

   call mpp_clock_end (initClock) !end initialization
   call mpp_clock_begin(mainClock) !begin main loop


   !------ ocean/slow-ice integration loop ------
   do nc = 1, num_cpld_calls
     if (do_chksum) call coupler_chksum('top_of_coupled_loop+', nc)

     !------ atmos/fast-land/fast-ice integration loop -------
     do na = 1, num_atmos_calls
       if (do_chksum) call coupler_chksum('top_of_atm_loop+', na)

       Time_atmos = Time_atmos + Time_step_atmos

       call sfc_boundary_layer (real(dt_atmos), Time_atmos, Atm, Land, Ice, &
                                Land_ice_atmos_boundary                     )
       if (do_chksum) call coupler_chksum('sfc+', na)

       !--- atmospheric dynamical core
       call update_atmos_model_dynamics( Atm )
       if (do_chksum) call coupler_chksum('model_dynamics+', na)

       !--- atmospheric radiation
       call update_atmos_model_radiation( Land_ice_atmos_boundary, Atm )
       if (do_chksum) call coupler_chksum('update_radiation+', na)

       !--- atmospheric phyiscal parameterizations - down phase
       call update_atmos_model_down( Land_ice_atmos_boundary, Atm )
       if (do_chksum) call coupler_chksum('atmos_model_down+', nc)

       !--- exchange fluxes down from atmosphere to surface
       call flux_down_from_atmos( Time_atmos, Atm, Land, Ice, &
                                  Land_ice_atmos_boundary,    &
                                  Atmos_land_boundary,        &
                                  Atmos_ice_boundary          )
       if (do_chksum) call coupler_chksum('flux_down+', nc)

       !--- fast phase land
       if (do_land ) then
         call update_land_model_fast ( Atmos_land_boundary, Land )
         if (do_chksum) call coupler_chksum('update_land+', na)
       endif 

       !--- fast phase ice
       call update_ice_model_fast  ( Atmos_ice_boundary,  Ice  )
       if (do_chksum) call coupler_chksum('update_ice+', na)

       !--- exchange fluxes up from surface to atmosphere
       call flux_up_to_atmos( Time_atmos, Land, Ice, Land_ice_atmos_boundary )
       if (do_chksum) call coupler_chksum('flux_up+', na)

       !--- atmospheric phyiscal parameterizations - up phase
       call update_atmos_model_up( Land_ice_atmos_boundary, Atm )
       if (do_chksum) call coupler_chksum('update_atmos_model_up+', na)

       !--- update atmospheric state
       call update_atmos_model_state( Atm )
       if (do_chksum) call coupler_chksum('update_model_state+', na)

     enddo

     !--- slow phase land
     if (do_land) then
       call update_land_model_slow ( Atmos_land_boundary, Land )
       if (do_chksum) call coupler_chksum('land_slow_diag+', nc)
     endif

     ! need flux call to put runoff and p_surf on ice grid
     ! call flux_land_to_ice ( Time_atmos, Land, Ice, Land_ice_boundary )

     !--- slow phase ice and proscribed ocean state
     call update_ice_model_slow ( Atmos_ice_boundary, Ice )
     if (do_chksum) call coupler_chksum('ice_model_slow+', nc)

   enddo

!-----------------------------------------------------------------------

   call mpp_clock_end(mainClock)
   call mpp_clock_begin(termClock)

   call coupler_end
   call mpp_clock_end(termClock)

   call fms_end

!-----------------------------------------------------------------------

   stop

contains

!#######################################################################

  subroutine coupler_init

!-----------------------------------------------------------------------
!   initialize all defined exchange grids and all boundary maps
!-----------------------------------------------------------------------
    integer :: total_days, total_seconds, unit, ierr, io
    integer :: n, gnlon, gnlat
    integer :: date(6), flags
    type (time_type) :: Run_length
    character(len=9) :: month
    logical :: use_namelist
    
    logical, allocatable, dimension(:,:) :: mask
    real,    allocatable, dimension(:,:) :: glon_bnd, glat_bnd
!-----------------------------------------------------------------------
!----- initialization timing identifiers ----

!----- read namelist -------
!----- for backwards compatibilty read from file coupler.nml -----

    if (file_exist('input.nml')) then
      unit = open_namelist_file ()
    else
      call error_mesg ('program coupler',  &
                       'namelist file input.nml does not exist', FATAL)
    endif
   
    ierr=1
    do while (ierr /= 0)
      read  (unit, nml=coupler_nml, iostat=io, end=10)
      ierr = check_nml_error (io, 'coupler_nml')
    enddo
10  call close_file (unit)

!----- write namelist to logfile -----

    call write_version_number (version, tag)
    if (mpp_pe() == mpp_root_pe()) write(stdlog(),nml=coupler_nml)

!----- allocate and set the pelist (to the global pelist) -----
    allocate( Atm%pelist  (mpp_npes()) )
    call mpp_get_current_pelist(Atm%pelist)

!----- read restart file -----

    if (file_exist('INPUT/coupler.res')) then
       call mpp_open( unit, 'INPUT/coupler.res', action=MPP_RDONLY )
       read (unit,*,err=999) calendar_type
       read (unit,*) date_init
       read (unit,*) date
       goto 998 !back to fortran-4
     ! read old-style coupler.res
   999 call mpp_close (unit)
       call mpp_open (unit, 'INPUT/coupler.res', action=MPP_RDONLY, form=MPP_NATIVE)
       read (unit) calendar_type
       read (unit) date
   998 call mpp_close(unit)
    else
       force_date_from_namelist = .true.
    endif       

!----- use namelist value (either no restart or override flag on) ---

    if ( force_date_from_namelist ) then

      if ( sum(current_date) <= 0 ) then
        call error_mesg ('program coupler',  &
             'no namelist value for current_date', FATAL)
      else
        date      = current_date
      endif

!----- override calendar type with namelist value -----

      select case( uppercase(trim(calendar)) )
      case( 'GREGORIAN' )
          calendar_type = GREGORIAN
      case( 'JULIAN' )
          calendar_type = JULIAN
      case( 'NOLEAP' )
          calendar_type = NOLEAP
      case( 'THIRTY_DAY' )
          calendar_type = THIRTY_DAY_MONTHS
      case( 'NO_CALENDAR' )
          calendar_type = NO_CALENDAR
      case default
          call mpp_error ( FATAL, 'COUPLER_MAIN: coupler_nml entry calendar must '// &
                                  'be one of GREGORIAN|JULIAN|NOLEAP|THIRTY_DAY|NO_CALENDAR.' )
      end select

    endif

    call set_calendar_type (calendar_type)

!----- write current/initial date actually used to logfile file -----

    if ( mpp_pe() == mpp_root_pe() ) then
      write (stdlog(),16) date(1),trim(month_name(date(2))),date(3:6)
    endif

 16 format ('  current date used = ',i4,1x,a,2i3,2(':',i2.2),' gmt') 

    !--- setting affinity
!$  call fms_affinity_set('ATMOS', use_hyper_thread, atmos_nthreads)
!$  call omp_set_num_threads(atmos_nthreads)

!-----------------------------------------------------------------------
!------ initialize diagnostics manager ------

    call diag_manager_init

!----- always override initial/base date with diag_manager value -----

    call get_base_date ( date_init(1), date_init(2), date_init(3), &
                         date_init(4), date_init(5), date_init(6)  )

!----- use current date if no base date ------

    if ( date_init(1) == 0 ) date_init = date

!----- set initial and current time types ------

    Time_init  = set_date (date_init(1), date_init(2), date_init(3), &
                           date_init(4), date_init(5), date_init(6))

    Time_atmos = set_date (date(1), date(2), date(3),  &
                           date(4), date(5), date(6))

!-----------------------------------------------------------------------
!----- compute the ending time (compute days in each month first) -----
!
!   (NOTE: if run length in months then starting day must be <= 28)

    if ( months > 0 .and. date(3) > 28 )     &
       call error_mesg ('program coupler',  &
            'if run length in months then starting day must be <= 28', FATAL)

    Time_end = Time_atmos
    total_days = 0
    do n = 1, months
      total_days = total_days + days_in_month(Time_end)
      Time_end = Time_atmos + set_time (0,total_days)
    enddo

    total_days    = total_days + days
    total_seconds = hours*3600 + minutes*60 + seconds
    Run_length    = set_time (total_seconds,total_days)
    Time_end      = Time_atmos + Run_length

    !Need to pass Time_end into diag_manager for multiple thread case.
    call diag_manager_set_time_end(Time_end)


!-----------------------------------------------------------------------
!----- write time stamps (for start time and end time) ------
   
    call mpp_open( unit, 'time_stamp.out', nohdrs=.TRUE. )

    month = month_name(date(2))
    if ( mpp_pe() == mpp_root_pe() ) write (unit,20) date, month(1:3)

    call get_date (Time_end, date(1), date(2), date(3),  &
                             date(4), date(5), date(6))
    month = month_name(date(2))
    if ( mpp_pe() == mpp_root_pe() ) write (unit,20) date, month(1:3)

    call mpp_close (unit)

 20 format (6i4,2x,a3)

!-----------------------------------------------------------------------
!----- compute the time steps ------

    Time_step_atmos = set_time (dt_atmos,0)
    Time_step_ocean = set_time (dt_ocean,0)
    num_cpld_calls  = Run_length / Time_step_ocean
    num_atmos_calls = Time_step_ocean / Time_step_atmos

!-----------------------------------------------------------------------
!------------------- some error checks ---------------------------------

!----- initial time cannot be greater than current time -------

    if ( Time_init > Time_atmos ) call error_mesg ('program coupler',  &
                    'initial time is greater than current time', FATAL)

!----- make sure run length is a multiple of ocean time step ------

    if ( num_cpld_calls * Time_step_ocean /= Run_length )  &
         call error_mesg ('program coupler',  &
         'run length must be multiple of ocean time step', FATAL)

! ---- make sure cpld time step is a multiple of atmos time step ----

    if ( num_atmos_calls * Time_step_atmos /= Time_step_ocean )  &
         call error_mesg ('program coupler',   &
         'atmos time step is not a multiple of the ocean time step', FATAL)


!------ initialize component models ------

    call  atmos_model_init (Atm,  Time_init, Time_atmos, Time_step_atmos, &
           .false.) ! do_concurrent_radiation

    call mpp_get_global_domain(Atm%Domain, xsize=gnlon, ysize=gnlat)
    allocate ( glon_bnd(gnlon+1,gnlat+1), glat_bnd(gnlon+1,gnlat+1) )
    call mpp_set_domain_symmetry(Atm%Domain, .true.)
    call mpp_global_field(Atm%Domain, Atm%lon_bnd, glon_bnd, position=CORNER)
    call mpp_global_field(Atm%Domain, Atm%lat_bnd, glat_bnd, position=CORNER)
    call mpp_set_domain_symmetry(Atm%Domain, .false.)

    call   land_model_init (Atmos_land_boundary, Land, &
                            Time_init, Time_atmos, Time_step_atmos, Time_step_ocean, &
#ifdef LAND_LAD
                            glon_bnd, glat_bnd, atmos_domain=Atm%Domain)
#else
                            glon_bnd, glat_bnd, domain_in=Atm%Domain)
#endif
    call    ice_model_init (Ice,  Time_init, Time_atmos, Time_step_atmos, Time_step_ocean, &
                            glon_bnd, glat_bnd, atmos_domain=Atm%Domain)

    call data_override_init(Atm_domain_in = Atm%domain)
    call data_override_init(Ice_domain_in = Ice%domain)
    call data_override_init(Land_domain_in = Land%domain)

!------------------------------------------------------------------------
!---- setup allocatable storage for fluxes exchanged between models ----
!---- use local grids -----

    call flux_exchange_init (Time_atmos, Atm, Land, Ice, &
                      !!!!!  atmos_land_boundary,        &
                             atmos_ice_boundary,         &
                             land_ice_atmos_boundary     )




!-----------------------------------------------------------------------
!---- open and close dummy file in restart dir to check if dir exists --

    call mpp_open( unit, 'RESTART/file' )
    call mpp_close(unit, MPP_DELETE)

!-----------------------------------------------------------------------

  end subroutine coupler_init

!#######################################################################

  subroutine coupler_end

    integer :: unit, date(6)
!-----------------------------------------------------------------------

!----- compute current date ------

    call get_date (Time_atmos, date(1), date(2), date(3),  &
                               date(4), date(5), date(6))

!----- check time versus expected ending time ----

    if (Time_atmos /= Time_end) call error_mesg ('program coupler',  &
            'final time does not match expected ending time', WARNING)

!----- write restart file ------

    call mpp_open( unit, 'RESTART/coupler.res', nohdrs=.TRUE. )
    if (mpp_pe() == mpp_root_pe())then
       write( unit, '(i6,8x,a)' )calendar_type, &
            '(Calendar: no_calendar=0, thirty_day_months=1, julian=2, gregorian=3, noleap=4)'

       write( unit, '(6i6,8x,a)' )date_init, &
            'Model start time:   year, month, day, hour, minute, second'
       write( unit, '(6i6,8x,a)' )date, &
            'Current model time: year, month, day, hour, minute, second'
    endif


!----- finalize model components, and output of diagnostic fields ----
    call atmos_model_end (Atm)
    call  land_model_end (Atmos_land_boundary, Land)
    call   ice_model_end (Ice)

    call diag_manager_end (Time_atmos)

    call  fms_io_exit
    call mpp_close(unit)

! call flux_exchange_end (Atm)


!-----------------------------------------------------------------------

  end subroutine coupler_end

!> \brief Print out checksums for several atm, land and ice variables
  subroutine coupler_chksum(id, timestep)

    character(len=*), intent(in) :: id
    integer         , intent(in) :: timestep

    type :: tracer_ind_type
      integer :: atm, ice, lnd ! indices of the tracer in the respective models
    end type tracer_ind_type
    integer                            :: n_atm_tr, n_lnd_tr, n_exch_tr
    integer                            :: n_atm_tr_tot, n_lnd_tr_tot
    integer                            :: i, tr, n, m, outunit
    type(tracer_ind_type), allocatable :: tr_table(:)
    character(32) :: tr_name

    call get_number_tracers (MODEL_ATMOS, num_tracers=n_atm_tr_tot, &
                             num_prog=n_atm_tr)
    call get_number_tracers (MODEL_LAND, num_tracers=n_lnd_tr_tot, &
                             num_prog=n_lnd_tr)

    ! Assemble the table of tracer number translation by matching names of
    ! prognostic tracers in the atmosphere and surface models; skip all atmos.
    ! tracers that have no corresponding surface tracers.
    allocate(tr_table(n_atm_tr))
    n = 1
    do i = 1,n_atm_tr
       call get_tracer_names( MODEL_ATMOS, i, tr_name )
       tr_table(n)%atm = i
       tr_table(n)%ice = get_tracer_index ( MODEL_ICE,  tr_name )
       tr_table(n)%lnd = get_tracer_index ( MODEL_LAND, tr_name )
      if (tr_table(n)%ice/=NO_TRACER .or. tr_table(n)%lnd/=NO_TRACER) n = n+1
    enddo
    n_exch_tr = n-1

100 FORMAT("CHECKSUM::",A32," = ",Z20)
101 FORMAT("CHECKSUM::",A16,a,'%',a," = ",Z20)


    outunit = stdout()
    write(outunit,*) 'BEGIN CHECKSUM(Atm):: ', id, timestep
    write(outunit,100) 'atm%t_bot', mpp_chksum(atm%t_bot)
    write(outunit,100) 'atm%z_bot', mpp_chksum(atm%z_bot)
    write(outunit,100) 'atm%p_bot', mpp_chksum(atm%p_bot)
    write(outunit,100) 'atm%u_bot', mpp_chksum(atm%u_bot)
    write(outunit,100) 'atm%v_bot', mpp_chksum(atm%v_bot)
    write(outunit,100) 'atm%p_surf', mpp_chksum(atm%p_surf)
    write(outunit,100) 'atm%gust', mpp_chksum(atm%gust)
    do tr = 1,n_exch_tr
       n = tr_table(tr)%atm
      if (n /= NO_TRACER) then
          call get_tracer_names( MODEL_ATMOS, tr_table(tr)%atm, tr_name )
          write(outunit,100) 'atm%'//trim(tr_name), mpp_chksum(Atm%tr_bot(:,:,n))
       endif
    enddo

    write(outunit,100) 'ice%t_surf', mpp_chksum(ice%t_surf)
    write(outunit,100) 'ice%rough_mom', mpp_chksum(ice%rough_mom)
    write(outunit,100) 'ice%rough_heat', mpp_chksum(ice%rough_heat)
    write(outunit,100) 'ice%rough_moist', mpp_chksum(ice%rough_moist)
    write(outunit,*) 'STOP CHECKSUM(Atm):: ', id, timestep

    deallocate(tr_table)


  end subroutine coupler_chksum



!#######################################################################

end program coupler_main

