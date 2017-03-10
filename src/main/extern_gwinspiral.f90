!--------------------------------------------------------------------------!
! The Phantom Smoothed Particle Hydrodynamics code, by Daniel Price et al. !
! Copyright (c) 2007-2017 The Authors (see AUTHORS)                        !
! See LICENCE file for usage and distribution conditions                   !
! http://users.monash.edu.au/~dprice/phantom                               !
!--------------------------------------------------------------------------!
!+
!  MODULE: extern_gwinspiral
!
!  DESCRIPTION:
!   Simulates the inspiral of two stars in a circular orbit caused by gravitational wave
!   radiation.
!   Author: Bernard Field (supervisor: James Wurster & Paul Lasky)
!
!  REFERENCES: e.g. Tong (2015) classical dynamics lecture notes
!
!  OWNER: Daniel Price
!
!  $Id$
!
!  RUNTIME PARAMETERS:
!    stop_ratio -- ratio of particles crossing CoM to indicate a merger
!
!  DEPENDENCIES: centreofmass, dump_utils, infile_utils, io, part, physcon,
!    units
!+
!--------------------------------------------------------------------------
module extern_gwinspiral
 implicit none
 !
 ! Runtime parameters
 !
 real,    public  :: stopratio = 0.005
 !
 ! local variables
 !
 integer, private :: n_threshhold
 integer, public  :: Nstar(2) = 0  ! give default value in case dump header not read
 real,    private :: fstar1_coef,fstar2_coef
 real,    private :: com(3),comstar1(3),comstar2(3),vcomstar1(3),vcomstar2(3),fstar1(3),fstar2(3)
 logical, private :: isseparate = .true.
 !
 ! subroutines
 !
 public  :: initialise_gwinspiral,gw_still_inspiralling,get_gw_force,get_gw_force_i
 public  :: read_options_gwinspiral, write_options_gwinspiral
 public  :: read_headeropts_gwinspiral, write_headeropts_gwinspiral
 private

contains

!-----------------------------------------------------------------------
!+
!  Initialises external force to determine how many particle are in
!  each star
!+
!-----------------------------------------------------------------------
subroutine initialise_gwinspiral(npart,ierr)
 use part,         only: massoftype,igas
 use physcon,      only: c
 use units,        only: unit_velocity
 integer, intent(in)       :: npart
 integer, intent(out)      :: ierr
 integer                   :: nerr
 real                      :: c_code
 !
 ! Calculate the number of particle required to 'merge' before the
 !  entire star is considered to be merged
 !
 n_threshhold = max(int(npart*stopratio),1)
 !
 ierr = 0
 nerr = 0
 if (Nstar(1) > 0) then
    write(*,"(2(a,i8))") ' Initialising inspiral, Nstar_1 = ',Nstar(1),' Nstar_2 = ',Nstar(2)
 else
    ierr = 1
    isseparate = .false.
    return
 endif
 if (nerr > 0) ierr = 1
 !
 ! Calculate force coefficients
 !
 c_code      = c/unit_velocity
 fstar1_coef = -32.0/5.0*Nstar(1)*Nstar(2)**3*massoftype(igas)**4/c_code**5
 fstar2_coef = -32.0/5.0*Nstar(2)*Nstar(1)**3*massoftype(igas)**4/c_code**5
 !
end subroutine initialise_gwinspiral
!-----------------------------------------------------------------------
!+
!  Determines if the neutron stars are still inspirialing
!  (i.e. do we need to calculate the GW energy)
!+
!-----------------------------------------------------------------------
subroutine gw_still_inspiralling(npart,xyzh,vxyzu,stopped_now)
 use centreofmass, only:get_centreofmass
 integer, intent(in)  :: npart
 real,    intent(in)  :: xyzh(:,:),vxyzu(:,:)
 logical, intent(out) :: stopped_now
 integer              :: i,k1,k2
 real                 :: dir,dx,dy,dz
 real                 :: mstar1,mstar2
 real                 :: dirstar1(3)

 stopped_now = .false.
 if ( isseparate ) then
    call get_centreofmass(comstar1,vcomstar1,Nstar(1),xyzh(:,1:Nstar(1)),&
                          vxyzu(:,1:Nstar(1)),mass=mstar1)
    call get_centreofmass(comstar2,vcomstar2,Nstar(2),xyzh(:,Nstar(1)+1:npart),&
                          vxyzu(:,Nstar(1)+1:npart),mass=mstar2)
    com  = (comstar1*mstar1 + comstar2*mstar2)/(mstar1+mstar2)
    dirstar1 = comstar1 - com ! The directional vector to star 1
    !
    ! Determine how many particle are 'in' star 2 when they should be 'in' star 1
    ! as determined by their CoM location
    !
    k1 = 0
!$omp parallel default(none) &
!$omp shared(nstar,xyzh,com,dirstar1) &
!$omp private(i,dx,dy,dz,dir) &
!$omp reduction(+:k1)
!$omp do
    do i=1,nstar(1)
       dx  = xyzh(1,i) - com(1)
       dy  = xyzh(2,i) - com(2)
       dz  = xyzh(3,i) - com(3)
       dir = dirstar1(1)*dx + dirstar1(2)*dy + dirstar1(3)*dz
       if ( dir < 0.0 ) k1 = k1 + 1
    enddo
!$omp enddo
!$omp end parallel
    !
    ! Determine how mnay particle are 'in' star 1 when they should be 'in' star 2
    ! as determined by their CoM location
    !
    k2 = 0
!$omp parallel default(none) &
!$omp shared(nstar,npart,xyzh,com,dirstar1) &
!$omp private(i,dx,dy,dz,dir) &
!$omp reduction(+:k2)
!$omp do
    do i=nstar(1)+1,npart
       dx  = xyzh(1,i) - com(1)
       dy  = xyzh(2,i) - com(2)
       dz  = xyzh(3,i) - com(3)
       dir = dirstar1(1)*dx + dirstar1(2)*dy + dirstar1(3)*dz
       if ( dir > 0.0 ) k2 = k2 + 1
    enddo
!$omp enddo
!$omp end parallel

    if (k1+k2 >= n_threshhold) then
       ! The stars have merged!
       isseparate = .false.    ! Stop emitting gravitational waves
       stopped_now = .true.    ! to trigger a print statement
    endif
 endif

end subroutine gw_still_inspiralling
!-----------------------------------------------------------------------
!+
!  Calculate the loss of energy (per star) from gravitational waves
!  This energy loss is in the form of a uniform reduction in force
!  Note: this is called immediately after gw_still_inspiralling, thus
!        the CoM's have just been calculated and stored
!+
!-----------------------------------------------------------------------
subroutine get_gw_force
 real :: dx,dy,dz,separation,vstar12,vstar22

 if ( isseparate ) then
    dx = comstar1(1) - comstar2(1)
    dy = comstar1(2) - comstar2(2)
    dz = comstar1(3) - comstar2(3)
    separation = sqrt(dx*dx + dy*dy + dz*dz)
    !
    ! Determine the speed of the two stars
    !
    vstar12 = dot_product(vcomstar1,vcomstar1)
    vstar22 = dot_product(vcomstar2,vcomstar2)
    !
    ! Compute the drag force vectors for each star
    !
    fstar1 = fstar1_coef * vcomstar1 / (vstar12*separation**5)
    fstar2 = fstar2_coef * vcomstar2 / (vstar22*separation**5)
 endif

end subroutine get_gw_force
!-----------------------------------------------------------------------
!+
!  Calculate the loss of energy (per particle) from gravitational waves
!  i.e. determine if the particle is in star 1, or star 2, and use the
!       required force
!+
!-----------------------------------------------------------------------
subroutine get_gw_force_i(i,fextxi,fextyi,fextzi,phi)
 integer, intent(in)    :: i
 real,    intent(inout) :: fextxi,fextyi,fextzi,phi

 if (i > 0 .and. isseparate ) then
    if (i <= nstar(1)) then
       fextxi = fstar1(1)
       fextyi = fstar1(2)
       fextzi = fstar1(3)
    else
       fextxi = fstar2(1)
       fextyi = fstar2(2)
       fextzi = fstar2(3)
    endif
 else
    fextxi = 0.0
    fextyi = 0.0
    fextzi = 0.0
 endif

end subroutine get_gw_force_i

!-----------------------------------------------------------------------
!+
!  writes input options to the input file
!+
!-----------------------------------------------------------------------
subroutine write_options_gwinspiral(iunit)
 use infile_utils, only:write_inopt
 integer, intent(in) :: iunit

 call write_inopt(stopratio,'stop_ratio','ratio of particles crossing CoM to indicate a merger',iunit)

end subroutine write_options_gwinspiral
!-----------------------------------------------------------------------
!+
!  reads input options from the input file
!+
!-----------------------------------------------------------------------
subroutine read_options_gwinspiral(name,valstring,imatch,igotall,ierr)
 use io, only:fatal
 character(len=*), intent(in)  :: name,valstring
 logical,          intent(out) :: imatch,igotall
 integer,          intent(out) :: ierr
 integer, save                 :: ngot = 0
 character(len=30), parameter  :: where = 'read_options_gwinspiral'

 imatch  = .true.
 igotall = .false.
 select case(trim(name))
 case('stop_ratio')
    read(valstring,*,iostat=ierr) stopratio
    if (stopratio < 0.)  call fatal(where,'Cannot have negative merger percentage of particle overlap')
    if (stopratio > 1.)  call fatal(where,'Cannot have ratio of particle overlap > 1')
    ngot = ngot + 1
 end select

 igotall = (ngot >= 1)

end subroutine read_options_gwinspiral

!-----------------------------------------------------------------------
!+
!  writes relevant options to the header of the dump file
!+
!-----------------------------------------------------------------------
subroutine write_headeropts_gwinspiral(hdr,ierr)
 use dump_utils, only:dump_h,add_to_header
 type(dump_h), intent(inout) :: hdr
 integer,      intent(out)   :: ierr

 ierr = 0
 call add_to_header(Nstar(1),'Nstar_1',hdr,ierr)
 call add_to_header(Nstar(2),'Nstar_2',hdr,ierr)

end subroutine write_headeropts_gwinspiral

!-----------------------------------------------------------------------
!+
!  reads relevant options from the header of the dump file
!+
!-----------------------------------------------------------------------
subroutine read_headeropts_gwinspiral(hdr,ierr)
 use dump_utils, only:dump_h,extract
 type(dump_h), intent(in)  :: hdr
 integer,      intent(out) :: ierr
 integer :: ierr1,ierr2

 ierr  = 0
 call extract('Nstar_1',Nstar(1),hdr,ierr1)
 call extract('Nstar_2',Nstar(2),hdr,ierr2)

 if (ierr1 /= 0 .or. ierr2 /= 0) then
    write(*,*) ' ERROR: NStar_1 and NStar_2 not present in dump file'
    ierr = 1
 endif

end subroutine read_headeropts_gwinspiral

end module extern_gwinspiral
