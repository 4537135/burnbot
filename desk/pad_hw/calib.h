// Touch calibration: from the touch chip's raw units to screen pixels, sx = a*rx + b*ry + c and
// sy = d*rx + e*ry + f, fitted by least squares to five taps on known targets.
//
// Plain C++ (no Arduino), so the Mac's simulator can test it.
#pragma once
#include <math.h>

namespace cal {

const int N = 5;
// Where the five crosses are drawn: the corners, then the middle.
const int TARGET[N][2] = {{30, 30}, {290, 30}, {290, 210}, {30, 210}, {160, 120}};
// A fit whose worst tap misses by this many pixels or more is thrown away.
const float MAX_ERROR = 18;

// What this pad's kit was calibrated to when it shipped (raw axes swapped and one reversed).
const float DEFAULT_AFFINE[6] = {0.01412f, 1.05956f, -10.11282f, -1.28073f, 0.00823f, 267.76937f};

inline void apply(const float m[6], int rx, int ry, int &sx, int &sy, int w = 320, int h = 240) {
  float x = m[0] * rx + m[1] * ry + m[2], y = m[3] * rx + m[4] * ry + m[5];
  sx = x < 0 ? 0 : x > w - 1 ? w - 1 : (int)lroundf(x);
  sy = y < 0 ? 0 : y > h - 1 ? h - 1 : (int)lroundf(y);
}

// 3x3 determinant
inline double det3(const double a[3][3]) {
  return a[0][0] * (a[1][1] * a[2][2] - a[1][2] * a[2][1]) -
         a[0][1] * (a[1][0] * a[2][2] - a[1][2] * a[2][0]) +
         a[0][2] * (a[1][0] * a[2][1] - a[1][1] * a[2][0]);
}

// Solves the normal equations for one axis with Cramer's rule. false when the taps are degenerate.
inline bool solve(const double ata[3][3], const double atb[3], double out[3]) {
  double d = det3(ata);
  if (fabs(d) < 1e-6) return false;
  for (int c = 0; c < 3; c++) {
    double m[3][3];
    for (int i = 0; i < 3; i++)
      for (int j = 0; j < 3; j++) m[i][j] = j == c ? atb[i] : ata[i][j];
    out[c] = det3(m) / d;
  }
  return true;
}

// raw: the five taps in raw units, in TARGET's order. Fills m and the worst miss in pixels.
// true when the fit is good enough to keep.
inline bool fit(const int raw[N][2], float m[6], float &worst) {
  double ata[3][3] = {}, bx[3] = {}, by[3] = {};
  for (int k = 0; k < N; k++) {
    double v[3] = {(double)raw[k][0], (double)raw[k][1], 1.0};
    for (int i = 0; i < 3; i++) {
      for (int j = 0; j < 3; j++) ata[i][j] += v[i] * v[j];
      bx[i] += v[i] * TARGET[k][0];
      by[i] += v[i] * TARGET[k][1];
    }
  }
  double cx[3], cy[3];
  worst = 999;
  if (!solve(ata, bx, cx) || !solve(ata, by, cy)) return false;
  worst = 0;
  for (int k = 0; k < N; k++) {
    double x = cx[0] * raw[k][0] + cx[1] * raw[k][1] + cx[2];
    double y = cy[0] * raw[k][0] + cy[1] * raw[k][1] + cy[2];
    double e = hypot(x - TARGET[k][0], y - TARGET[k][1]);
    if (e > worst) worst = (float)e;
  }
  for (int i = 0; i < 3; i++) {
    m[i] = (float)cx[i];
    m[3 + i] = (float)cy[i];
  }
  return worst < MAX_ERROR;
}

}  // namespace cal
