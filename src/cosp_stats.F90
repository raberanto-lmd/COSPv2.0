! %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
! Copyright (c) 2015, Regents of the University of Colorado
! All rights reserved.
!
! Redistribution and use in source and binary forms, with or without modification, are 
! permitted provided that the following conditions are met:
!
! 1. Redistributions of source code must retain the above copyright notice, this list of 
!    conditions and the following disclaimer.
!
! 2. Redistributions in binary form must reproduce the above copyright notice, this list
!    of conditions and the following disclaimer in the documentation and/or other 
!    materials provided with the distribution.
!
! 3. Neither the name of the copyright holder nor the names of its contributors may be 
!    used to endorse or promote products derived from this software without specific prior
!    written permission.
!
! THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY 
! EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF 
! MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL 
! THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, 
! SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT 
! OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS 
! INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
! LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
! OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
!
! History:
! Jul 2007 - A. Bodas-Salcedo - Initial version
! Jul 2008 - A. Bodas-Salcedo - Added capability of producing outputs in standard grid
! Oct 2008 - J.-L. Dufresne   - Bug fixed. Assignment of Npoints,Nlevels,Nhydro,Ncolumns 
!                               in COSP_STATS
! Oct 2008 - H. Chepfer       - Added PARASOL reflectance arguments
! Jun 2010 - T. Yokohata, T. Nishimura and K. Ogochi - Added NEC SXs optimisations
! Jan 2013 - G. Cesana        - Added betaperp and temperature arguments 
!                             - Added phase 3D/3Dtemperature/Map output variables in diag_lidar 
! May 2015 - D. Swales        - Modified for cosp2.0 
! Nov 2018 - T. Michibata     - Added CloudSat+MODIS Warmrain Diagnostics
! May 2020 - R. Guzman        - Added linear interpolation routines to perform vertical 
!                               interpolations for the lidar and radar simulators by adding
!                               new source file src/cosp_interp.F90. Also added subroutines
!                               called : COSP_INTERP_NEW_GRID, COSP_FIND_GRID_INDEXES and
!                               COSP_MIXING_REGRID_METHODS
!! %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
MODULE MOD_COSP_STATS
  USE COSP_KINDS, ONLY: wp
  USE MOD_COSP_CONFIG, &
      ONLY: R_UNDEF,          R_GROUND,         &
            SGCLD_CLR,        SGCLD_ST,         &
            SGCLD_CUM,                          &
            CWP_THRESHOLD,    COT_THRESHOLD,    &
            CFODD_NDBZE,      CFODD_NICOD,      &
            CFODD_BNDRE,      CFODD_BNDZE,      &
            CFODD_NCLASS,                       &
            CFODD_DBZE_MIN,   CFODD_DBZE_MAX,   &
            CFODD_ICOD_MIN,   CFODD_ICOD_MAX,   &
            CFODD_DBZE_WIDTH, CFODD_ICOD_WIDTH, &
            CFODD_HISTDBZE,   CFODD_HISTICOD,   &
            WR_NREGIME
  USE COSP_PHYS_CONSTANTS,  ONLY: tmelt
  USE MOD_INTERP

  IMPLICIT NONE
CONTAINS

  !%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
  !---------- SUBROUTINE COSP_MIXING_REGRID_METHODS -------------
  !%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
  SUBROUTINE COSP_MIXING_REGRID_METHODS(Npoints,Ncolumns,Nlevels,zfull,zhalf,y,Nglevels,newgrid_mid,newgrid_bot,newgrid_top,r,log_units)
   implicit none
   ! Input arguments
   integer,intent(in) :: Npoints  !# of grid points
   integer,intent(in) :: Nlevels  !# of levels
   integer,intent(in) :: Ncolumns !# of columns
   real(wp),dimension(Npoints,Nlevels),intent(in) :: zfull ! Height at model levels [m] (Middle of model layer)
   real(wp),dimension(Npoints,Nlevels),intent(in) :: zhalf ! Height at half model levels [m] (Bottom of model layer)
   real(wp),dimension(Npoints,Ncolumns,Nlevels),intent(in) :: y     ! Variable to be changed to a different grid
   integer,intent(in) :: Nglevels  !# levels in the new grid
   real(wp),dimension(Nglevels),intent(in) :: newgrid_mid ! Mid altitude of new levels    [m]
   real(wp),dimension(Nglevels),intent(in) :: newgrid_bot ! Lower boundary of new levels  [m]
   real(wp),dimension(Nglevels),intent(in) :: newgrid_top ! Upper boundary of new levels  [m]
   logical,optional,intent(in) :: log_units ! log units, need to convert to linear units
   ! Output
   real(wp),dimension(Npoints,Ncolumns,Nglevels),intent(out) :: r ! Variable on new grid

   ! Local variables
   real(wp),dimension(Npoints,Ncolumns,Nglevels) :: r_lin ! Variable linearly interpolated
   real(wp),dimension(Npoints,Ncolumns,Nglevels) :: r_leg ! Variable with former (legacy)
                                                          ! vertical regridding method
   integer :: i,j,k
   logical :: lunits
   real(wp),dimension(Npoints,1,Nlevels)  :: dz_mod        ! Model grid layer thicknesses
   real(wp),dimension(Npoints,1,Nglevels) :: dz_mod_out    ! Model grid layer thicknesses
                                                           ! interpolated to output grid
   real(wp),dimension(Npoints,1,Nglevels) :: dz_out        ! Output grid layer thicknesses
   real(wp),dimension(Npoints,Nglevels)   :: method_weight ! Weighting function

   lunits=.false.
   if (present(log_units)) lunits=log_units

   r = 0._wp
   r_lin = 0._wp
   r_leg = 0._wp

! Computing model (dz_mod) and output (dz_out) grid layer thicknesses on their own vertical grid
  do i=1,Npoints
    dz_mod(i,1,:) = 2.*(zfull(i,:)-zhalf(i,:))
    dz_out(i,1,:) = newgrid_top(:)-newgrid_bot(:)
  enddo

!print *, 'Just after dz_mod, dz_mod(1,1,:)=',dz_mod(1,1,:)
!print *, 'Just after dz_mod, dz_out(1,1,:)=',dz_out(1,1,:)

! Interpolating dz_mod (model layer thickness) to output vertical grid,
! gives an "average" dz_mod corresponding to each output layer needed for the weighting
   do i=1,Npoints
     call interp_linear(1, Nlevels, zfull(i,:), dz_mod(i,1,:), Nglevels, newgrid_mid, &
                        dz_mod_out(i,1,:), .false.)
   enddo

!print *, 'Just after interp dz_mod_out, dz_mod_out(1,1,:)=',dz_mod_out(1,1,:)

! Legacy vertical regridding method
   call cosp_change_vertical_grid(Npoints,Ncolumns,Nlevels,zfull,zhalf,&
            y,Nglevels,newgrid_bot,newgrid_top,r_leg,lunits)
! Linear interpolation method
   call cosp_interp_new_grid(Npoints,Ncolumns,Nlevels,zfull,zhalf,&
            y,Nglevels,newgrid_mid,newgrid_top,r_lin,lunits)

! Computing a vertical regrid method weight as a function of
! model vs output grid layer thicknesses
! method_weight --> 1 (dz_mod_out << dz_out), or method_weight --> 0 (dz_mod_out >> dz_out)
    method_weight(:,:) = dz_out(:,1,:)/(dz_mod_out(:,1,:)+dz_out(:,1,:))

!print *, 'Just after method weight, method_weight(1,:)=', method_weight(1,:)

! Mixing/weighting both regridding methods
  do i=1,Npoints
    do j=1,Ncolumns
      do k=1,Nglevels
        if (r_leg(i,j,k) .eq. R_GROUND) then
          r(i,j,k) = R_GROUND
        else if ( (r_leg(i,j,k) .eq. R_UNDEF) .and. (r_lin(i,j,k) .ne. R_UNDEF) ) then
          r(i,j,k) = r_lin(i,j,k)
        else if ( (r_leg(i,j,k) .ne. R_UNDEF) .and. (r_lin(i,j,k) .eq. R_UNDEF) ) then
          r(i,j,k) = r_leg(i,j,k)
        else
          if (lunits) then
            if ( (r_leg(i,j,k) .ne. R_UNDEF) .and. (r_lin(i,j,k) .ne. R_UNDEF) ) then
              r(i,j,k) = ( 10._wp**(r_leg(i,j,k)/10._wp) )*method_weight(i,k) + &
                         ( 10._wp**(r_lin(i,j,k)/10._wp) )*(1-method_weight(i,k))
            else
              r(i,j,k) = 0._wp
            endif
            if ( r(i,j,k) <= 0.0 ) then
              r(i,j,k) = R_UNDEF
            else
              r(i,j,k) = 10._wp*log10( r(i,j,k) )
            endif
          else
            r(i,j,k) = r_leg(i,j,k)*method_weight(i,k) + &
                       r_lin(i,j,k)*(1-method_weight(i,k))
          endif
        endif
      enddo
    enddo
  enddo

  END SUBROUTINE COSP_MIXING_REGRID_METHODS


  !%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
  !---------- SUBROUTINE COSP_FIND_GRID_INDEXES -------------
  !%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
  SUBROUTINE COSP_FIND_GRID_INDEXES(Npoints, Nlevels, zhalf, dz, index_new)
   implicit none
   ! Input arguments
   integer,intent(in) :: Npoints  !# of grid points
   integer,intent(in) :: Nlevels  !# of levels
   real(wp),dimension(Npoints,Nlevels),intent(in) :: zhalf ! Height at half model levels [m] (Bottom of model layer)
   real(wp),intent(in) :: dz ! Output vertical grid thickness 
   integer,dimension(Npoints),intent(out) :: index_new ! Index (from ground) where to
                                    ! start upward vertical interpolation in new grid

    ! Local Variables
    integer :: i,k
    integer,dimension(Npoints) :: index_old ! Index (from ground) where to start upward
                                            ! vertical interpolation in old grid

    ! Initialization
    index_old = 0

    ! Determine the altitude index in old grid where to start interpolation
    do i=1,Npoints
       do k=1,Nlevels
          if ( ((zhalf(i,k+1)-zhalf(i,k)) .gt. dz ) .and. (index_old(i) .eq. 0) ) then
            index_old(i) = k
            ! Determine the altitude index in new grid where to start interpolation
            index_new(i) = floor(zhalf(i,index_old(i))/dz)
	  endif
       enddo
    enddo

  END SUBROUTINE COSP_FIND_GRID_INDEXES


  !%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
  !---------- SUBROUTINE COSP_INTERP_NEW_GRID -------------
  !%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
  SUBROUTINE COSP_INTERP_NEW_GRID(Npoints, Ncolumns, Nlevels, zfull, zhalf, &
             y, Nglevels, newgrid, newgrid_top, r, log_units)
   implicit none
   ! Input arguments
   integer,intent(in) :: Npoints  !# of grid points
   integer,intent(in) :: Nlevels  !# of levels
   integer,intent(in) :: Ncolumns !# of columns
   real(wp),dimension(Npoints,Nlevels),intent(in) :: zfull ! Height at model levels [m]
   real(wp),dimension(Npoints,Nlevels),intent(in) :: zhalf ! Height at half model levels [m] (Bottom of model layer)
   real(wp),dimension(Npoints,Ncolumns,Nlevels),intent(in) :: y     ! Variable to be changed to a different grid
   integer,intent(in) :: Nglevels  !# levels in the new grid
   real(wp),dimension(Nglevels),intent(in) :: newgrid     ! Height at new vertical levels  [m]
   real(wp),dimension(Nglevels),intent(in) :: newgrid_top ! Upper boundary of new levels  [m]
   logical,optional,intent(in) :: log_units ! log units, need to convert to linear units
   ! Output
   real(wp),dimension(Npoints,Ncolumns,Nglevels),intent(out) :: r ! Variable on new grid

   ! Local variables
   integer :: i,j,k
   logical :: lunits
   integer :: l

   lunits=.false.
   if (present(log_units)) lunits=log_units

   r = 0._wp

   ! Simultaneous interpolation of the Ncolumns, loop over all Npoints of the model
   do i=1,Npoints
     call interp_linear(Ncolumns, Nlevels, zfull(i,:), y(i,:,:), Nglevels, newgrid, &
                        r(i,:,:), lunits)
   enddo

   ! Set points under surface to R_UNDEF, and change to dBZ if necessary
   do k=1,Nglevels
     do j=1,Ncolumns
       do i=1,Npoints
         if (newgrid_top(k) > zhalf(i,1)) then ! Level above model bottom level
           if (lunits) then
             if (r(i,j,k) <= 0.0) then
               r(i,j,k) = R_UNDEF
             else
               r(i,j,k) = 10._wp*log10(r(i,j,k))
             endif
           endif
         else ! Level below surface
           r(i,j,k) = R_GROUND
         endif
       enddo
     enddo
   enddo

  END SUBROUTINE COSP_INTERP_NEW_GRID


  !%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
  !---------- SUBROUTINE COSP_CHANGE_VERTICAL_GRID ----------------
  !%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
SUBROUTINE COSP_CHANGE_VERTICAL_GRID(Npoints,Ncolumns,Nlevels,zfull,zhalf,y,Nglevels,newgrid_bot,newgrid_top,r,log_units)
   implicit none
   ! Input arguments
   integer,intent(in) :: Npoints  !# of grid points
   integer,intent(in) :: Nlevels  !# of levels
   integer,intent(in) :: Ncolumns !# of columns
   real(wp),dimension(Npoints,Nlevels),intent(in) :: zfull ! Height at model levels [m] (Bottom of model layer)
   real(wp),dimension(Npoints,Nlevels),intent(in) :: zhalf ! Height at half model levels [m] (Bottom of model layer)
   real(wp),dimension(Npoints,Ncolumns,Nlevels),intent(in) :: y     ! Variable to be changed to a different grid
   integer,intent(in) :: Nglevels  !# levels in the new grid
   real(wp),dimension(Nglevels),intent(in) :: newgrid_bot ! Lower boundary of new levels  [m]
   real(wp),dimension(Nglevels),intent(in) :: newgrid_top ! Upper boundary of new levels  [m]
   logical,optional,intent(in) :: log_units ! log units, need to convert to linear units
   ! Output
   real(wp),dimension(Npoints,Ncolumns,Nglevels),intent(out) :: r ! Variable on new grid

   ! Local variables
   integer :: i,j,k
   logical :: lunits
   integer :: l
   real(wp) :: w ! Weight
   real(wp) :: dbb, dtb, dbt, dtt ! Distances between edges of both grids
   integer :: Nw  ! Number of weights
   real(wp) :: wt  ! Sum of weights
   real(wp),dimension(Nlevels) :: oldgrid_bot,oldgrid_top ! Lower and upper boundaries of model grid
   real(wp) :: yp ! Local copy of y at a particular point.
              ! This allows for change of units.

   lunits=.false.
   if (present(log_units)) lunits=log_units

   r = 0._wp

   do i=1,Npoints
     ! Calculate tops and bottoms of new and old grids
     oldgrid_bot = zhalf(i,:)
     oldgrid_top(1:Nlevels-1) = oldgrid_bot(2:Nlevels)
     oldgrid_top(Nlevels) = zfull(i,Nlevels) +  zfull(i,Nlevels) - zhalf(i,Nlevels) ! Top level symmetric
     l = 0 ! Index of level in the old grid
     ! Loop over levels in the new grid
     do k = 1,Nglevels
       Nw = 0 ! Number of weigths
       wt = 0._wp ! Sum of weights
       ! Loop over levels in the old grid and accumulate total for weighted average
       do
         l = l + 1
         w = 0.0 ! Initialise weight to 0
         ! Distances between edges of both grids
         dbb = oldgrid_bot(l) - newgrid_bot(k)
         dtb = oldgrid_top(l) - newgrid_bot(k)
         dbt = oldgrid_bot(l) - newgrid_top(k)
         dtt = oldgrid_top(l) - newgrid_top(k)
         if (dbt >= 0.0) exit ! Do next level in the new grid
         if (dtb > 0.0) then
           if (dbb <= 0.0) then
             if (dtt <= 0) then
               w = dtb
             else
               w = newgrid_top(k) - newgrid_bot(k)
             endif
           else
             if (dtt <= 0) then
               w = oldgrid_top(l) - oldgrid_bot(l)
             else
               w = -dbt
             endif
           endif
           ! If layers overlap (w/=0), then accumulate
           if (w /= 0.0) then
             Nw = Nw + 1
             wt = wt + w
             do j=1,Ncolumns
               if (lunits) then
                 if (y(i,j,l) /= R_UNDEF) then
                   yp = 10._wp**(y(i,j,l)/10._wp)
                 else
                   yp = 0._wp
                 endif
               else
                 yp = y(i,j,l)
               endif
               r(i,j,k) = r(i,j,k) + w*yp
             enddo
           endif
         endif
       enddo
       l = l - 2
       if (l < 1) l = 0
       ! Calculate average in new grid
       if (Nw > 0) then
         do j=1,Ncolumns
           r(i,j,k) = r(i,j,k)/wt
         enddo
       endif
     enddo
   enddo

   ! Set points under surface to R_UNDEF, and change to dBZ if necessary
   do k=1,Nglevels
     do j=1,Ncolumns
       do i=1,Npoints
         if (newgrid_top(k) > zhalf(i,1)) then ! Level above model bottom level
           if (lunits) then
             if (r(i,j,k) <= 0.0) then
               r(i,j,k) = R_UNDEF
             else
               r(i,j,k) = 10._wp*log10(r(i,j,k))
             endif
           endif
         else ! Level below surface
           r(i,j,k) = R_GROUND
         endif
       enddo
     enddo
   enddo

END SUBROUTINE COSP_CHANGE_VERTICAL_GRID

  !%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
  !------------- SUBROUTINE COSP_LIDAR_ONLY_CLOUD -----------------
  ! (c) 2008, Lawrence Livermore National Security Limited Liability Corporation.
  ! All rights reserved.
  !%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
  SUBROUTINE COSP_LIDAR_ONLY_CLOUD(Npoints, Ncolumns, Nlevels, beta_tot, beta_mol,       &
     Ze_tot, lidar_only_freq_cloud, tcc, radar_tcc, radar_tcc2)
    ! Inputs
    integer,intent(in) :: &
         Npoints,       & ! Number of horizontal gridpoints
         Ncolumns,      & ! Number of subcolumns
         Nlevels          ! Number of vertical layers
    real(wp),dimension(Npoints,Nlevels),intent(in) :: &
         beta_mol         ! Molecular backscatter
    real(wp),dimension(Npoints,Ncolumns,Nlevels),intent(in) :: &
         beta_tot,      & ! Total backscattered signal
         Ze_tot           ! Radar reflectivity
    ! Outputs
    real(wp),dimension(Npoints,Nlevels),intent(out) :: &
         lidar_only_freq_cloud
    real(wp),dimension(Npoints),intent(out) ::&
         tcc,       & !
         radar_tcc, & !
         radar_tcc2   !
    
    ! local variables
    real(wp) :: sc_ratio
    real(wp),parameter :: &
         s_cld=5.0, &
         s_att=0.01
    integer :: flag_sat,flag_cld,pr,i,j,flag_radarcld,flag_radarcld_no1km,j_1km
    
    lidar_only_freq_cloud = 0._wp
    tcc = 0._wp
    radar_tcc = 0._wp
    radar_tcc2 = 0._wp
    do pr=1,Npoints
       do i=1,Ncolumns
          flag_sat = 0
          flag_cld = 0
          flag_radarcld = 0 !+JEK
          flag_radarcld_no1km=0 !+JEK
          ! look for j_1km from bottom to top
          j = 1
          do while (Ze_tot(pr,i,j) .eq. R_GROUND)
             j = j+1
          enddo
          j_1km = j+1  !this is the vertical index of 1km above surface  
          
          do j=1,Nlevels
             sc_ratio = beta_tot(pr,i,j)/beta_mol(pr,j)
             if ((sc_ratio .le. s_att) .and. (flag_sat .eq. 0)) flag_sat = j
             if (Ze_tot(pr,i,j) .lt. -30.) then  !radar can't detect cloud
                if ( (sc_ratio .gt. s_cld) .or. (flag_sat .eq. j) ) then  !lidar sense cloud
                   lidar_only_freq_cloud(pr,j)=lidar_only_freq_cloud(pr,j)+1. !top->surf
                   flag_cld=1
                endif
             else  !radar sense cloud (z%Ze_tot(pr,i,j) .ge. -30.)
                flag_cld=1
                flag_radarcld=1
                if (j .gt. j_1km) flag_radarcld_no1km=1              
             endif
          enddo !levels
          if (flag_cld .eq. 1) tcc(pr)=tcc(pr)+1._wp
          if (flag_radarcld .eq. 1) radar_tcc(pr)=radar_tcc(pr)+1.
          if (flag_radarcld_no1km .eq. 1) radar_tcc2(pr)=radar_tcc2(pr)+1.        
       enddo !columns
    enddo !points
    lidar_only_freq_cloud=lidar_only_freq_cloud/Ncolumns
    tcc=tcc/Ncolumns
    radar_tcc=radar_tcc/Ncolumns
    radar_tcc2=radar_tcc2/Ncolumns
    
    ! Unit conversion
    where(lidar_only_freq_cloud /= R_UNDEF) &
            lidar_only_freq_cloud = lidar_only_freq_cloud*100._wp
    where(tcc /= R_UNDEF) tcc = tcc*100._wp
    where(radar_tcc /= R_UNDEF) radar_tcc = radar_tcc*100._wp
    where(radar_tcc2 /= R_UNDEF) radar_tcc2 = radar_tcc2*100._wp
    
  END SUBROUTINE COSP_LIDAR_ONLY_CLOUD
  
  !%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
  !-----------------------  SUBROUTINE COSP_DIAG_WARMRAIN ------------------------
  ! (c) 2018, Research Institute for Applied Mechanics (RIAM), Kyushu Univ.
  ! All rights reserved.
  ! * Purpose:    1) Diagnose Contoured Frequency by Optical Depth Diagram (CFODD)
  !                  from CloudSat Radar and MODIS retrievals.
  !               2) Diagnose Warm-Rain Occurrence Frequency (nonprecip/drizzle/rain)
  !                  from CloudSat Radar.
  ! * History:    2018.01.25 (T.Michibata): Test run
  !               2018.05.17 (T.Michibata): update for COSP2
  !               2018.09.19 (T.Michibata): modified I/O
  !               2018.11.22 (T.Michibata): minor revisions
  !               2020.05.27 (T.Michibata and X.Jing): bug-fix for frac_out dimsize
  ! * References: Michibata et al. (GMD'19, doi:10.5194/gmd-12-4297-2019)
  !               Michibata et al. (GRL'20, doi:10.1029/2020GL088340)
  !               Suzuki et al. (JAS'10, doi:10.1175/2010JAS3463.1)
  !               Suzuki et al. (JAS'15, doi:10.1175/JAS-D-14-0265.1)
  !               Jing et al. (JCLIM'19, doi:10.1175/jcli-d-18-0789.1)
  ! * Contact:    Takuro Michibata (RIAM, Kyushu University, Japan).
  !               E-mail: michibata@riam.kyushu-u.ac.jp
  !%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
  SUBROUTINE COSP_DIAG_WARMRAIN( Npoints, Ncolumns, Nlevels,           & !! in
                                 temp,    zlev,     delz,              & !! in
                                 lwp,     liqcot,   liqreff, liqcfrc,  & !! in
                                 iwp,     icecot,   icereff, icecfrc,  & !! in
                                 fracout, dbze,                        & !! in
                                 cfodd_ntotal,                         & !! inout
                                 wr_occfreq_ntotal                     ) !! inout

    ! Inputs
    integer, intent(in) :: &
         Npoints,          & ! Number of horizontal gridpoints
         Ncolumns,         & ! Number of subcolumns
         Nlevels             ! Number of vertical layers
    real(wp), dimension(Npoints), intent(in) :: &
         lwp,              & ! MODIS LWP [kg m-2]
         liqcot,           & ! MODIS liq. COT
         liqreff,          & ! MODIS liq. Reff [m]
         liqcfrc             ! MODIS liq. cloud fraction
    real(wp), dimension(Npoints), intent(in) :: &
         iwp,              & ! MODIS IWP [kg m-2]
         icecot,           & ! MODIS ice COT
         icereff,          & ! MODIS ice Reff [m]
         icecfrc             ! MODIS ice cloud fraction
    real(wp), dimension(Npoints,Nlevels), intent(in) :: &
         zlev,             & ! altitude [m] for model level
         delz                ! delta Z [m] (= zlevm(k+1)-zlemv(k))
    real(wp), dimension(Npoints,1,Nlevels),intent(in) :: &
         temp                ! temperature [K]
    real(wp), dimension(Npoints,Ncolumns,Nlevels),intent(in) :: &
         fracout,          & ! SCOPS subcolumn retrieval
         dbze                ! Radar reflectivity [dBZe]

    ! Outputs
    real(wp),dimension(Npoints,CFODD_NDBZE,CFODD_NICOD,CFODD_NCLASS),intent(inout) :: &
         cfodd_ntotal        ! # of CFODD samples for each ICOD/dBZe bin
    real(wp),dimension(Npoints,WR_NREGIME),intent(inout) :: &
         wr_occfreq_ntotal   ! # of SLWC samples

    ! Local variables
    integer  :: i, j, k
    integer  :: ix, iy
    integer  :: kctop, kcbtm
    integer  :: icls
    integer  :: iregime
    real     :: cmxdbz
    real(wp) :: diagcgt   !! diagnosed cloud geometric thickness [m]
    real(wp) :: diagdbze  !! diagnosed dBZe
    real(wp) :: diagicod  !! diagnosed in-cloud optical depth
    real(wp) :: cbtmh     !! diagnosed in-cloud optical depth
    real(wp), dimension(Npoints,Ncolumns,Nlevels) :: icod  !! in-cloud optical depth (ICOD)
    logical  :: octop, ocbtm, oslwc
    integer, dimension(Npoints,Ncolumns,Nlevels) :: fracout_int  !! fracout (decimal to integer)
    fracout_int(:,:,:) = NINT( fracout(:,:,:) )  !! assign an integer subpixcel ID (0=clear-sky; 1=St; 2=Cu)

    !! initialize
    cfodd_ntotal(:,:,:,:)  = 0._wp
    wr_occfreq_ntotal(:,:) = 0._wp
    icod(:,:,:) = 0._wp

    do i = 1, Npoints
       !! check by MODIS retrieval
       if ( lwp(i)     .le.  CWP_THRESHOLD  .or.  &
          & liqcot(i)  .le.  COT_THRESHOLD  .or.  &
          & liqreff(i) .lt.  CFODD_BNDRE(1) .or.  &
          & liqreff(i) .gt.  CFODD_BNDRE(4) .or.  &
          & iwp(i)     .gt.  CWP_THRESHOLD  .or.  &       !! exclude ice cloud
          & icecot(i)  .gt.  COT_THRESHOLD  .or.  &       !! exclude ice cloud
          & icereff(i) .gt.  CFODD_BNDRE(1)       ) then  !! exclude ice cloud
          cycle
       else
          !! retrieve the CFODD array based on Reff
          icls = 0
          if (    liqreff(i) .ge. CFODD_BNDRE(1) .and. liqreff(i) .lt. CFODD_BNDRE(2) ) then
             icls = 1
          elseif( liqreff(i) .ge. CFODD_BNDRE(2) .and. liqreff(i) .lt. CFODD_BNDRE(3) ) then
             icls = 2
          elseif( liqreff(i) .ge. CFODD_BNDRE(3) .and. liqreff(i) .le. CFODD_BNDRE(4) ) then
             icls = 3
          endif
       endif

       !CDIR NOLOOPCHG
       do j = 1, Ncolumns, 1
          octop = .true.  !! initialize
          ocbtm = .true.  !! initialize
          kcbtm =     0   !! initialize
          kctop =     0   !! initialize
          !CDIR NOLOOPCHG
          do k = Nlevels, 1, -1  !! scan from cloud-bottom to cloud-top
             if ( dbze(i,j,k) .eq. R_GROUND .or. &
                  dbze(i,j,k) .eq. R_UNDEF       ) cycle
             if ( ocbtm                              .and. &
                & fracout_int(i,j,k) .ne. SGCLD_CLR  .and. &
                & dbze(i,j,k)        .ge. CFODD_DBZE_MIN   ) then
                ocbtm = .false.  !! cloud bottom detected
                kcbtm = k
                kctop = k
             endif
             if (       octop                        .and. &  !! scan cloud-top
                & .not. ocbtm                        .and. &  !! cloud-bottom already detected
                & fracout_int(i,j,k) .ne. SGCLD_CLR  .and. &  !! exclude clear sky
                & dbze(i,j,k)        .ge. CFODD_DBZE_MIN   ) then
                kctop = k  !! update
             endif
          enddo  !! k loop
          if( ocbtm ) cycle  !! cloud wasn't detected in this subcolumn
          !! check SLWC?
          if( temp(i,1,kctop) .lt. tmelt ) cycle  !! return to the j (subcolumn) loop
          oslwc = .true.
          cmxdbz = CFODD_DBZE_MIN  !! initialized

          !CDIR NOLOOPCHG
          do k = kcbtm, kctop, -1
             cmxdbz = max( cmxdbz, dbze(i,j,k) )  !! column maximum dBZe update
             if ( fracout_int(i,j,k) .eq. SGCLD_CLR  .or.  &
                & fracout_int(i,j,k) .eq. SGCLD_CUM  .or.  &
                & dbze       (i,j,k) .lt. CFODD_DBZE_MIN   ) then
                oslwc = .false.
             endif
          enddo
          if ( .not. oslwc ) cycle  !! return to the j (subcolumn) loop

          !! warm-rain occurrence frequency
          iregime = 0
          if( cmxdbz .lt. CFODD_BNDZE(1) ) then
             iregime = 1  !! non-precipitating
          elseif( cmxdbz .ge. CFODD_BNDZE(1) .and. cmxdbz .lt. CFODD_BNDZE(2) ) then
             iregime = 2  !! drizzling
          elseif( cmxdbz .ge. CFODD_BNDZE(2) ) then
             iregime = 3  !! raining
          endif
          wr_occfreq_ntotal(i,iregime) = wr_occfreq_ntotal(i,iregime) + 1._wp

          !! retrievals of ICOD and dBZe bin for CFODD plane
          diagcgt = zlev(i,kctop) - zlev(i,kcbtm)
          cbtmh   = zlev(i,kcbtm)
          !CDIR NOLOOPCHG
          do k = kcbtm, kctop, -1
             if( k .eq. kcbtm ) then
                diagicod = liqcot(i)
             else
                diagicod = liqcot(i) * ( 1._wp - ( (zlev(i,k)-cbtmh)/diagcgt)**(5._wp/3._wp) )
             endif
             icod(i,j,k) = min( diagicod, CFODD_ICOD_MAX )
          enddo

       enddo  ! j (Ncolumns)

       !! # of samples for CFODD (joint 2d-histogram dBZe vs ICOD)
       call hist2d( dbze(i,1:Ncolumns,1:Nlevels), icod(i,1:Ncolumns,1:Nlevels), &
                  & Ncolumns*Nlevels,                                           &
                  & CFODD_HISTDBZE, CFODD_NDBZE, CFODD_HISTICOD, CFODD_NICOD,   &
                  & cfodd_ntotal( i, 1:CFODD_NDBZE, 1:CFODD_NICOD, icls )       )

    enddo     ! i (Npoints)

  RETURN
  END SUBROUTINE COSP_DIAG_WARMRAIN

  ! ######################################################################################
  ! FUNCTION hist1D
  ! ######################################################################################
  function hist1d(Npoints,var,nbins,bins)
    ! Inputs
    integer,intent(in) :: &
         Npoints, & ! Number of points in input array
         Nbins      ! Number of bins for sorting
    real(wp),intent(in),dimension(Npoints) :: &
         var        ! Input variable to be sorted
    real(wp),intent(in),dimension(Nbins+1) :: &
         bins       ! Histogram bins [lowest,binTops]  
    ! Outputs
    real(wp),dimension(Nbins) :: &
         hist1d     ! Output histogram      
    ! Local variables
    integer :: ij
    
    do ij=2,Nbins+1  
       hist1D(ij-1) = count(var .ge. bins(ij-1) .and. var .lt. bins(ij))
       if (count(var .eq. R_GROUND) .ge. 1) hist1D(ij-1)=R_UNDEF
    enddo
    
  end function hist1D
  
  ! ######################################################################################
  ! SUBROUTINE hist2D
  ! ######################################################################################
  subroutine hist2D(var1,var2,npts,bin1,nbin1,bin2,nbin2,jointHist)
    implicit none
    
    ! INPUTS
    integer, intent(in) :: &
         npts,  & ! Number of data points to be sorted
         nbin1, & ! Number of bins in histogram direction 1 
         nbin2    ! Number of bins in histogram direction 2
    real(wp),intent(in),dimension(npts) :: &
         var1,  & ! Variable 1 to be sorted into bins
         var2     ! variable 2 to be sorted into bins
    real(wp),intent(in),dimension(nbin1+1) :: &
         bin1     ! Histogram bin 1 boundaries
    real(wp),intent(in),dimension(nbin2+1) :: &
         bin2     ! Histogram bin 2 boundaries
    ! OUTPUTS
    real(wp),intent(out),dimension(nbin1,nbin2) :: &
         jointHist
    
    ! LOCAL VARIABLES
    integer :: ij,ik
    
    do ij=2,nbin1+1
       do ik=2,nbin2+1
          jointHist(ij-1,ik-1)=count(var1 .ge. bin1(ij-1) .and. var1 .lt. bin1(ij) .and. &
               var2 .ge. bin2(ik-1) .and. var2 .lt. bin2(ik))        
       enddo
    enddo
  end subroutine hist2D
END MODULE MOD_COSP_STATS
