#include "kernels.h"
#include "util.h"
#include "assert.h"

/*
 __device__ float rho(float *iL, float *iR, int nc, float lambda)
 {
 float sum = 0.f;
 // Sum the error for all channels
 for (int c = 0; c < nc; c++)
 {
 sum += fabs(iL[c] - iR[c]);
 }
 return sum * lambda;
 }

 __global__ void g_project_p_c(float * P, float * IL, float *IR, int w, int h,
 int nc, int gc, float lambda, float gamma_min)
 {
 int x = threadIdx.x + blockDim.x * blockIdx.x;
 int y = threadIdx.y + blockDim.y * blockIdx.y;

 if (x < w && y < h)
 {
 // Consider every disparity channel
 for (int g = 0; g < gc; g++)
 {
 // p1..2 must hold true to the constraint that sqrt(p1² + p2²) <= 1
 // p3 must hold true to the constraint that |p3| <= rho(x, gamma)
 int max_z = 3 * gc;
 int idx_p1_z = 0 * gc + g;
 int idx_p2_z = 1 * gc + g;
 int idx_p3_z = 2 * gc + g;

 float p1 = read_data(P, w, h, max_z, x, y, idx_p1_z);
 float p2 = read_data(P, w, h, max_z, x, y, idx_p2_z);
 float p3 = read_data(P, w, h, max_z, x, y, idx_p3_z);

 // p1, p2
 float tmp = max(1.f, sqrtf(square(p1) + square(p2)));
 p1 = p1 / tmp;
 p2 = p2 / tmp;

 // p3
 float iL[3];
 float iR[3];

 // Save image data to temporary arrays
 for (int c = 0; c < nc; c++)
 {
 iL[c] = read_data(IL, w, h, nc, x, y, c);
 // Use the disparity value of this layer of P
 // index of gamma runs from 0...gc, thus offset by gamma_min (eg. -16)
 iR[c] = read_data(IR, w, h, nc, x + gamma_min + g, y, c);
 }

 float r = rho(iL, iR, nc, lambda);
 p3 = p3 / max(1.f, fabs(p3) / r);

 // write the results back to P
 write_data(P, p1, w, h, max_z, x, y, idx_p1_z);
 write_data(P, p2, w, h, max_z, x, y, idx_p2_z);
 write_data(P, p3, w, h, max_z, x, y, idx_p3_z);
 }
 }
 }

 __global__ void g_project_phi_d(float * Phi, int w, int h, int gc)
 {
 // phi must be truncated to the interval [0,1]
 int x = threadIdx.x + blockDim.x * blockIdx.x;
 int y = threadIdx.y + blockDim.y * blockIdx.y;

 if (x < w && y < h)
 {
 for (int g = 1; g < gc - 1; g++)
 {
 float phi = read_data(Phi, w, h, gc, x, y, g);
 write_data(Phi, clamp(phi, 0, 1), w, h, gc, x, y, g);
 }
 // Phi of (x, y, gamma_min) = 1
 write_data(Phi, 1.f, w, h, gc, x, y, 0);
 // Phi of (x, y, gamma_max) = 0
 write_data(Phi, 0.f, w, h, gc, x, y, gc - 1);
 }
 }

 __global__ void g_update_p(float * P, float *Grad3_Phi, int w, int h, int gc,
 float tau_d)
 {
 // p^k+1 = PC(p^k + tau_d * grad3(Phi))
 int x = threadIdx.x + blockDim.x * blockIdx.x;
 int y = threadIdx.y + blockDim.y * blockIdx.y;

 if (x < w && y < h)
 {
 // p has 3 channels
 int pc = 3;
 // maximum z index for P and Grad3_Phi
 int max_z = 3 * gc;
 int idx_z;

 float p, p_next, grad3_phi;

 for (int g = 0; g < gc; g++)
 {
 for (int i = 0; i < pc; i++)
 {
 idx_z = i * gc + g;
 p = read_data(P, w, h, max_z, x, y, idx_z);
 grad3_phi = read_data(Grad3_Phi, w, h, max_z, x, y, idx_z);

 p_next = p + tau_d * grad3_phi;

 // Write back to P
 write_data(P, p_next, w, h, max_z, x, y, idx_z);
 }
 }
 }
 }

 __global__ void g_update_phi(float *Phi, float *Div3_P, int w, int h, int gc,
 float tau_p)
 {
 // phi^k+1 = PD(phi^k + div3(p^k))
 int x = threadIdx.x + blockDim.x * blockIdx.x;
 int y = threadIdx.y + blockDim.y * blockIdx.y;

 if (x < w && y < h)
 {
 float phi, phi_next, div3_p;

 for (int g = 0; g < gc; g++)
 {
 phi = read_data(Phi, w, h, gc, x, y, g);
 div3_p = read_data(Div3_P, w, h, gc, x, y, g);
 phi_next = phi + tau_p * div3_p;

 // Write back to Phi
 write_data(Phi, phi_next, w, h, gc, x, y, g);
 }
 }
 }

 __global__ void g_grad3(float *Phi, float *Grad3_Phi, int w, int h, int gc,
 float dx, float dy, float dg)
 {
 // Gradient 3 is defined via forward differences
 int x = threadIdx.x + blockDim.x * blockIdx.x;
 int y = threadIdx.y + blockDim.y * blockIdx.y;

 if (x < w && y < h)
 {
 for (int g = 0; g < gc; g++)
 {
 float phi = read_data(Phi, w, h, gc, x, y, g);
 // Compute the gradients
 float gradx = (read_data(Phi, w, h, gc, x + 1, y, g) - phi) / dx;
 float grady = (read_data(Phi, w, h, gc, x, y + 1, g) - phi) / dy;
 float gradg = (read_data(Phi, w, h, gc, x, y, g + 1) - phi) / dg;

 // 3 channels on the gradient with the same layout as p
 int max_z = 3 * gc;
 int idx_phi_x = g;
 int idx_phi_y = g + gc;
 int idx_phi_g = g + 2 * gc;

 // Write the forward differences in different directions stacked into phi
 write_data(Grad3_Phi, gradx, w, h, max_z, x, y, idx_phi_x);
 write_data(Grad3_Phi, grady, w, h, max_z, x, y, idx_phi_y);
 write_data(Grad3_Phi, gradg, w, h, max_z, x, y, idx_phi_g);
 }

 }
 }

 __global__ void g_div3(float *P, float *Div3_P, int w, int h, int gc, float dx,
 float dy, float dg)
 {
 int x = threadIdx.x + blockDim.x * blockIdx.x;
 int y = threadIdx.y + blockDim.y * blockIdx.y;

 if (x < w && y < h)
 {
 int idx_p1_z, idx_p2_z, idx_p3_z, idx_p3_z_1, // Idx for p3 with z - 1
 max_z;

 float p1, p2, p3, div3_p;

 for (int g = gc - 1; g > 0; g--)
 {
 // Calculate the indices for p1, p2, p3
 max_z = 3 * gc;
 idx_p1_z = g;
 idx_p2_z = g + gc;
 idx_p3_z = g + 2 * gc;
 // create last index, that may only lie in the range of the p3 index, thus clamp manually
 idx_p3_z_1 = clamp(idx_p3_z - 1, 2 * gc, (3 * gc) - 1);

 p1 = read_data(P, w, h, max_z, x, y, idx_p1_z);
 p2 = read_data(P, w, h, max_z, x, y, idx_p2_z);
 p3 = read_data(P, w, h, max_z, x, y, idx_p3_z);

 // Divergence 3 is defined as the sum of backward differences
 div3_p = (p1 - read_data(P, w, h, max_z, x - 1, y, idx_p1_z)) / dx
 + (p2 - read_data(P, w, h, max_z, x, y - 1, idx_p2_z)) / dy
 + (p3 - read_data(P, w, h, max_z, x, y, idx_p3_z_1)) / dg;

 write_data(Div3_P, div3_p, w, h, gc, x, y, g);
 }
 }
 }

 __global__ void g_compute_u(float *Phi, float *U, int w, int h, int gamma_min,
 int gamma_max)
 {
 int x = threadIdx.x + blockDim.x * blockIdx.x;
 int y = threadIdx.y + blockDim.y * blockIdx.y;

 int u = gamma_min;
 int gc = gamma_max - gamma_min;

 if (x < w && y < h)
 {
 for (int g = 0; g < gc; g++)
 {
 // use mu = 0.5 aka round to nearest integer value
 u += round(read_data(Phi, w, h, gc, x, y, g));
 }

 write_data(U, u, w, h, x, y);
 }
 }
 */

// TODO: Use shared memory to load data from iL and iR to shared memory
__global__ void g_compute_rho(float *iL, float *iR, float *Rho, int w, int h,
		int nc, int gamma_min, int gamma_max, float lambda)
{
	int x = threadIdx.x + blockDim.x * blockIdx.x;
	int y = threadIdx.y + blockDim.y * blockIdx.y;

	if (x < w && y < h)
	{
		// Iterate all possible disparities
		for (int g = gamma_min; g < gamma_max; g++)
		{
			float r = 0.f;

			// Calculate absolute error between iL and iR
			for (int c = 0; c < nc; c++)
			{
				float il = read_data(iL, w, h, nc, x, y, c);
				float ir = read_data(iR, w, h, nc, x - g, y, c);
				r += lambda * fabs(il - ir);
			}
			// Create entry at layer g (normalized to range from 0 to gamma_max - gamma_min)
			int gc = gamma_max - gamma_min;
			 //write_data(Rho, r, w, h, nc * gc, x, y, g - gamma_min);
              write_data(Rho, r, w, h, gc, x, y, g - gamma_min);
		}
	}
}

__global__ void g_init_phi(float *Phi, int w, int h, int gc)
{
	int x = threadIdx.x + blockDim.x * blockIdx.x;
	int y = threadIdx.y + blockDim.y * blockIdx.y;
	if (x < w && y < h)
	{
		// Initialize gamma_min to 1
		write_data(Phi, 1.f, w, h, gc, x, y, 0);
	}
}

__global__ void g_update_phi(float *Phi, float *Div3_P, int w, int h, int gc,
		float tau_p)
{
	int x = threadIdx.x + blockDim.x * blockIdx.x;
	int y = threadIdx.y + blockDim.y * blockIdx.y;

	if (x < w && y < h)
	{
		// Only do this for the layers that don't get set anyways
		for (int g = 1; g < gc - 1; g++)
		{
			float phi = read_data(Phi, w, h, gc, x, y, g);
			float div3_p = read_data(Div3_P, w, h, gc, x, y, g);
			float upd = fclamp(phi + tau_p * div3_p, 0.f, 1.f);
			write_data(Phi, upd, w, h, gc, x, y, g);
		}
		// Set phi(x, gamma_min) = 1 and phi(x, gamma_max) = 0
		write_data(Phi, 1.f, w, h, gc, x, y, 0);
		write_data(Phi, 0.f, w, h, gc, x, y, gc - 1);
	}
}

__global__ void g_update_p(float *P, float *Grad3_Phi, float *Rho, int w, int h,
		int gc, float tau_d)
{
	int x = threadIdx.x + blockDim.x * blockIdx.x;
	int y = threadIdx.y + blockDim.y * blockIdx.y;

	if (x < w && y < h)
	{
		int max_z, idx_p1_z, idx_p2_z, idx_p3_z;
		float p1, p2, p3, g1, g2, g3, pabs, r;

		for (int g = 0; g < gc; g++)
		{
			max_z = 3 * gc;
			idx_p1_z = 0 * gc + g;
			idx_p2_z = 1 * gc + g;
			idx_p3_z = 2 * gc + g;

			p1 = read_data(P, w, h, max_z, x, y, idx_p1_z);
			p2 = read_data(P, w, h, max_z, x, y, idx_p2_z);
			p3 = read_data(P, w, h, max_z, x, y, idx_p3_z);

			g1 = read_data(Grad3_Phi, w, h, max_z, x, y, idx_p1_z);
			g2 = read_data(Grad3_Phi, w, h, max_z, x, y, idx_p2_z);
			g3 = read_data(Grad3_Phi, w, h, max_z, x, y, idx_p3_z);

			// Update
			p1 = p1 + tau_d * g1;
			p2 = p2 + tau_d * g2;
			p3 = p3 + tau_d * g3;

			// Project p1 and p2 to C
			pabs = sqrt(square(p1) + square(p2));
			if(pabs > 1.f)
			{
				p1 = p1 / pabs;
				p2 = p2 / pabs;
			}

			r = read_data(Rho, w, h, gc, x, y, g);
			if(fabs(p3) > r)
				p3 = copysignf(r, p3); // r with sign of p3

			write_data(P, p1, w, h, max_z, x, y, idx_p1_z);
			write_data(P, p2, w, h, max_z, x, y, idx_p2_z);
			write_data(P, p3, w, h, max_z, x, y, idx_p3_z);
		}
	}
}

__global__ void g_grad3(float *Phi, float *Grad3_Phi, int w, int h, int gc,
		float dx, float dy, float dg)
{
	int x = threadIdx.x + blockDim.x * blockIdx.x;
	int y = threadIdx.y + blockDim.y * blockIdx.y;

	if (x < w && y < h)
	{
		for (int g = 0; g < gc; g++)
		{
			int max_z = 3 * gc;
			int idx_p1_z = 0 * gc + g;
			int idx_p2_z = 1 * gc + g;
			int idx_p3_z = 2 * gc + g;

			float phi = read_data(Phi, w, h, gc, x, y, g);
			float grad_x = (read_data(Phi, w, h, gc, x + 1, y, g) - phi) / dx;
			float grad_y = (read_data(Phi, w, h, gc, x, y + 1, g) - phi) / dy;
			float grad_g = (read_data(Phi, w, h, gc, x, y, g + 1) - phi) / dg;

			write_data(Grad3_Phi, grad_x, w, h, max_z, x, y, idx_p1_z);
			write_data(Grad3_Phi, grad_y, w, h, max_z, x, y, idx_p2_z);
			write_data(Grad3_Phi, grad_g, w, h, max_z, x, y, idx_p3_z);
		}
	}
}

__global__ void g_div3(float *P, float *Div3_P, int w, int h, int gc, float dx,
		float dy, float dg)
{
	int x = threadIdx.x + blockDim.x * blockIdx.x;
	int y = threadIdx.y + blockDim.y * blockIdx.y;

	if (x < w && y < h)
	{
		for (int g = 0; g < gc; g++)
		{
			int max_z = 3 * gc;
			int idx_p1_z = 0 * gc + g;
			int idx_p2_z = 1 * gc + g;
			int idx_p3_z = 2 * gc + g;

			float div3 = 0.f;
			float p1 = read_data(P, w, h, max_z, x, y, idx_p1_z);
			float p2 = read_data(P, w, h, max_z, x, y, idx_p2_z);
			float p3 = read_data(P, w, h, max_z, x, y, idx_p3_z);

			div3 += (p1 - read_data(P, w, h, max_z, x - 1, y, idx_p1_z)) / dx;
			div3 += (p2 - read_data(P, w, h, max_z, x, y - 1, idx_p2_z)) / dy;
			// Make sure p3(x, y, g - 1) does not reach into p2 values, else div(p3) is 0 anyways
			if (g > 0)
				div3 += (p3 - read_data(P, w, h, max_z, x, y, idx_p3_z - 1)) / dg;

			write_data(Div3_P, div3, w, h, gc, x, y, g);
		}
	}
}

__global__ void g_compute_u(float *Phi, float *U, int w, int h, int gamma_min,
		int gamma_max)
{
	int x = threadIdx.x + blockDim.x * blockIdx.x;
	int y = threadIdx.y + blockDim.y * blockIdx.y;

	if (x < w && y < h)
	{
		float u = gamma_min;
		for (int g = 0; g < gamma_max - gamma_min; g++)
		{
			u += round(read_data(Phi, w, h, gamma_max - gamma_min, x, y, g));
		}
		write_data(U, u, w, h, x, y);
	}
}

__global__ void g_compute_energy(float *Grad3_Phi, float *Phi, float *Rho, float *energy,int w, int h, int gc, float lambda){
    int x = threadIdx.x + blockDim.x * blockIdx.x;
	int y = threadIdx.y + blockDim.y * blockIdx.y;
    
   
    __shared__ float sm;   
    if(x < w && y < h)
     { 
       float e=0.f;
       for (int g = 0; g < gc; g++)
         {
          int idx_p3_z = 2 * gc + g;
          float phi   = read_data(Phi, w, h, gc, x, y, g);
          float grad_g = read_data(Grad3_Phi, w, h, (3*gc), x, y, idx_p3_z);
          float phi_x = read_data(Phi, w, h, gc, x+1, y, g);
          float phi_y = read_data(Phi, w, h, gc, x, y+1, g);
           e += (read_data(Rho, w, h, gc, x, y, g)*grad_g)+sqrt(square(phi_x - phi) + square(phi_y - phi));
          }

   
		// Add up the energy of this block
		atomicAdd(&sm, e);
		__syncthreads();

		// Add this to the current (global) energy
		if (threadIdx.x == 0)
			atomicAdd(energy, sm);
       
     }
}


/*
__global__ void g_compute_energy3(float * U,float *Rho,float *Phi, 
		float * energy, int w, int h, int gc, float dg)
{
	int x = threadIdx.x + blockDim.x * blockIdx.x;
	int y = threadIdx.y + blockDim.y * blockIdx.y;

	__shared__ float sm;

	if (x < w && y < h)
	{
		float e = 0.f;

		// Regularizing term: |grad(u(x))|
		int u = read_data(U, w, h, x, y);
		int ux = read_data(U, w, h, x + 1, y);
		int uy = read_data(U, w, h, x, y + 1);
		e += sqrt(square(ux - u) + square(uy - u));

		// Data term: rho(u(x), x)

		for (int g = 0; g < nc; g++)
		{
		   float phi   = read_data(Phi, w, h, gc, x, y, g);
           float grad_gamma= (read_data(Phi, w, h, gc, x, y, g + 1) - phi) / dg;
           float phi_x = read_data(Phi, w, h, gc, x+1, y, g);
           float phi_y = read_data(Phi, w, h, gc, x, y+1, g);
           e += (read_data(Rho, w, h, gc, x, y, g)*grad_gamma);	
		}
        
        

		// Add up the energy of this block
		atomicAdd(&sm, e);
		__syncthreads();

		// Add this to the current (global) energy
		if (threadIdx.x == 0)
			atomicAdd(energy, sm);
	}

}
*/
/*
__global__ void g_compute_energy(float * U, float *IL, float *IR,
		float * energy, int w, int h, int nc, float lambda)
{
	int x = threadIdx.x + blockDim.x * blockIdx.x;
	int y = threadIdx.y + blockDim.y * blockIdx.y;

	__shared__ float sm;

	if (x < w && y < h)
	{
		float e = 0.f;

		// Regularizing term: |grad(u(x))|
		int u = read_data(U, w, h, x, y);
		int ux = read_data(U, w, h, x + 1, y);
		int uy = read_data(U, w, h, x, y + 1);
		e += sqrt(square(ux - u) + square(uy - u));

		// Data term: rho(u(x), x)

		for (int c = 0; c < nc; c++)
		{
			float il = read_data(IL, w, h, nc, x, y, c);
			float ir = read_data(IR, w, h, nc, x + u, y, c);
			e += lambda * fabs(il - ir);
		}
        
        

		// Add up the energy of this block
		atomicAdd(&sm, e);
		__syncthreads();

		// Add this to the current (global) energy
		if (threadIdx.x == 0)
			atomicAdd(energy, sm);
	}

}
*/
__global__ void g_compute_depth(float * Disparities, float *Depths, int w,
		int h, float baseline, int f, int doffs)
{
	int x = threadIdx.x + blockDim.x * blockIdx.x;
	int y = threadIdx.y + blockDim.y * blockIdx.y;

	if (x < w && y < h)
	{
		float d = read_data(Disparities, w, h, x, y);
		write_data(Depths, baseline * f / (d + doffs), w, h, x, y);
	}
}

__global__ void g_compute_g_matrix(float *Depths, float *G, int w, int h,
		float z_f, float radius)
{
	int x = threadIdx.x + blockDim.x * blockIdx.x;
	int y = threadIdx.y + blockDim.y * blockIdx.y;

	if (x < w && y < h)
	{
		float z = read_data(Depths, w, h, x, y);
		write_data(G, powf(fabs(z - z_f), radius), w, h, x, y);
	}
}

__global__ void g_apply_g(float *Grad_x, float *Grad_y, float *G, int w, int h,
		int nc)
{
	int x = threadIdx.x + blockDim.x * blockIdx.x;
	int y = threadIdx.y + blockDim.y * blockIdx.y;

	if (x < w && y < h)
	{
		float g = read_data(G, w, h, x, y);
		float gx, gy;

		for (int c = 0; c < nc; c++)
		{
			gx = read_data(Grad_x, w, h, nc, x, y, c);
			gy = read_data(Grad_y, w, h, nc, x, y, c);

			write_data(Grad_x, gx * g, w, h, nc, x, y, c);
			write_data(Grad_y, gy * g, w, h, nc, x, y, c);
		}
	}
}

__global__ void g_update_step(float *I, float *D, int w, int h, int nc,
		float tau)
{
	int x = threadIdx.x + blockDim.x * blockIdx.x;
	int y = threadIdx.y + blockDim.y * blockIdx.y;
	int c = threadIdx.z + blockDim.z * blockIdx.z;

	float upd;

	if (x < w && y < h)
	{
		float i = read_data(I, w, h, nc, x, y, c);
		float d = read_data(D, w, h, nc, x, y, c);
		upd = i + tau * d;
		write_data(I, upd, w, h, nc, x, y, c);
	}
}